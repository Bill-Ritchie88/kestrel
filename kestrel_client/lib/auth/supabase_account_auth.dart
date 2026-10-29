import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'account_auth.dart';

/// Account sign-in for this build: Supabase Auth when the build has its
/// settings, connecting in the background so the first screen does not wait
/// for it, and the stand-in that hides it otherwise.
AccountAuth startAccountAuth() =>
    AppConfig.accountSignIn ? DeferredAccountAuth(_connect()) : const UnavailableAccountAuth();

/// True when the page was opened by Google sending the browser back (with
/// ?code= or ?error=): the sign-in is finished as soon as Supabase is up.
bool returningFromAccountSignIn() {
  if (!kIsWeb || !AppConfig.accountSignIn) return false;
  final query = Uri.base.queryParameters;
  return query.containsKey('code') || query.containsKey('error');
}

Future<AccountAuth> _connect() async {
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    // The anon (public) key; Supabase now calls it the publishable key.
    publishableKey: AppConfig.supabaseAnonKey,
    // "Nothing is saved on this device": the Supabase session lives in memory
    // only, like the Kestrel token. (Google's sign-in still keeps its one-off
    // PKCE verifier across the redirect, as the flow requires.)
    authOptions: const FlutterAuthClientOptions(
      localStorage: EmptyLocalStorage(),
      persistSession: false,
    ),
  );
  final auth = Supabase.instance.client.auth;
  // initialize() has already exchanged the ?code= Google sent back. If the
  // address says Google answered but there is no session, it was cancelled
  // or refused: the sign-in page says so.
  final failed = returningFromAccountSignIn() && auth.currentSession == null;
  return SupabaseAccountAuth(auth,
      pendingError: failed ? 'Signing in with Google didn\'t finish. Please try again.' : null);
}

class SupabaseAccountAuth implements AccountAuth {
  SupabaseAccountAuth(this._auth, {String? pendingError})
      : _pendingError = pendingError,
        _pendingTaken = false;

  final GoTrueClient _auth;
  String? _pendingError;
  bool _pendingTaken;

  /// When each address was last sent a code. Supabase answers a wrong code
  /// and an expired one with the same error, so the age tells them apart.
  final _sentAt = <String, DateTime>{};

  /// The code expiry configured in Supabase (Auth -> Email OTP expiry).
  static const codeLifetime = Duration(seconds: 600);

  @override
  bool get available => true;

  @override
  ValueListenable<bool> get ready => const AlwaysReady();

  AccountIdentity? _identity(Session? session) {
    final user = session?.user;
    final email = user?.email;
    if (session == null || user == null || email == null) return null;
    return AccountIdentity(
      accessToken: session.accessToken,
      email: email,
      provider: (user.appMetadata['provider'] as String?) ?? 'email',
    );
  }

  @override
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo}) async {
    try {
      await _auth.signInWithOAuth(OAuthProvider.google, redirectTo: redirectTo);
    } catch (e) {
      throw _map(e);
    }
    // The page is now leaving for Google; the identity arrives through
    // takePendingIdentity() when it comes back.
    if (kIsWeb) return null;
    throw const AccountAuthException(AccountAuthError.other, 'Signing in with Google didn\'t finish. Please try again.');
  }

  @override
  Future<void> sendEmailCode(String email) async {
    try {
      await _auth.signInWithOtp(email: email, shouldCreateUser: true);
      _sentAt[email.toLowerCase()] = DateTime.now();
    } catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<AccountIdentity> verifyEmailCode({required String email, required String code}) async {
    try {
      final res = await _auth.verifyOTP(type: OtpType.email, email: email, token: code);
      final identity = _identity(res.session);
      if (identity == null) {
        throw const AccountAuthException(AccountAuthError.other, 'Signing in didn\'t finish. Please try again.');
      }
      return identity;
    } on AccountAuthException {
      rethrow;
    } catch (e) {
      final sent = _sentAt[email.toLowerCase()];
      final expired = sent != null && DateTime.now().difference(sent) >= codeLifetime;
      throw _map(e, codeExpired: expired);
    }
  }

  @override
  AccountIdentity? takePendingIdentity() {
    if (_pendingTaken) return null;
    _pendingTaken = true;
    return _identity(_auth.currentSession);
  }

  @override
  String? takePendingError() {
    final e = _pendingError;
    _pendingError = null;
    return e;
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // Signing out of Kestrel must not fail because Supabase is unreachable.
    }
  }

  static AccountAuthException _map(Object e, {bool codeExpired = false}) {
    if (e is AuthRetryableFetchException) {
      return const AccountAuthException(
          AccountAuthError.unreachable, 'Sign-in could not be reached. Check your connection and try again.');
    }
    if (e is AuthException) {
      final code = e.code ?? '';
      if (e.statusCode == '429' || code.contains('rate_limit')) {
        return AccountAuthException(AccountAuthError.rateLimited, e.message);
      }
      if (code == 'otp_expired' || code == 'invalid_otp' || e.statusCode == '403') {
        return AccountAuthException(codeExpired ? AccountAuthError.expiredCode : AccountAuthError.invalidCode, e.message);
      }
      return AccountAuthException(AccountAuthError.other, e.message);
    }
    return const AccountAuthException(
        AccountAuthError.unreachable, 'Sign-in could not be reached. Check your connection and try again.');
  }
}
