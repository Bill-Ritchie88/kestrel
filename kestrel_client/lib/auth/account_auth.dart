/// Signing in with an account (Google, or a 6-digit code emailed to the
/// passenger). Supabase Auth proves who the person is; the REST tier then
/// links that account to a booking (POST /api/auth/account).
///
/// The sign-in page talks to this interface, not to Supabase directly, so the
/// widget tests can drive every state with a fake.
library;

import 'package:flutter/foundation.dart';

/// Why an account action failed, in terms the sign-in page can act on.
enum AccountAuthError {
  /// Too many codes asked for in a short time.
  rateLimited,

  /// The code typed doesn't match.
  invalidCode,

  /// The code is older than its 10 minutes.
  expiredCode,

  /// Supabase could not be reached.
  unreachable,

  other,
}

class AccountAuthException implements Exception {
  const AccountAuthException(this.kind, this.message);
  final AccountAuthError kind;
  final String message;

  @override
  String toString() => message;
}

/// Who Supabase says the person is, once they have signed in.
class AccountIdentity {
  const AccountIdentity({required this.accessToken, required this.email, required this.provider});

  /// The Supabase access token, exchanged at POST /api/auth/account.
  final String accessToken;
  final String email;

  /// 'google' or 'email'.
  final String provider;
}

abstract class AccountAuth {
  /// False when the app was built without the Supabase settings: the
  /// sign-in page then offers only the booking reference and the staff key.
  bool get available;

  /// True once the sign-in service is connected. It connects in the
  /// background while the first screen is already showing, so the Google and
  /// email buttons appear at once and wait (disabled) until this is true.
  ValueListenable<bool> get ready;

  /// Starts Google sign-in. In a browser this leaves the page and comes back
  /// to [redirectTo]; the identity is then picked up by
  /// [takePendingIdentity] and this returns null. Returns the identity
  /// directly where nothing redirects.
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo});

  /// Emails a 6-digit code to [email], creating the account if it is new.
  Future<void> sendEmailCode(String email);

  Future<AccountIdentity> verifyEmailCode({required String email, required String code});

  /// A sign-in that completed while the app was loading (the Google redirect
  /// back). Returned once.
  AccountIdentity? takePendingIdentity();

  /// Why a Google sign-in that came back to the app didn't finish (e.g. it
  /// was cancelled). Returned once.
  String? takePendingError();

  Future<void> signOut();
}

/// [AccountAuth.ready] for a service that is ready from the start.
class AlwaysReady implements ValueListenable<bool> {
  const AlwaysReady();

  @override
  bool get value => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Account sign-in whose service is still connecting: [connecting] resolves
/// to the real one. Until then nothing is signed in and the buttons wait; if
/// it fails, every action says the service could not be reached.
class DeferredAccountAuth implements AccountAuth {
  DeferredAccountAuth(Future<AccountAuth> connecting) {
    _connected = connecting.catchError((Object _) => const UnreachableAccountAuth())
      ..then((auth) {
        _auth = auth;
        _ready.value = true;
      });
  }

  late final Future<AccountAuth> _connected;
  AccountAuth? _auth;
  final _ready = ValueNotifier(false);

  @override
  bool get available => true;

  @override
  ValueListenable<bool> get ready => _ready;

  @override
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo}) async =>
      (await _connected).signInWithGoogle(redirectTo: redirectTo);

  @override
  Future<void> sendEmailCode(String email) async => (await _connected).sendEmailCode(email);

  @override
  Future<AccountIdentity> verifyEmailCode({required String email, required String code}) async =>
      (await _connected).verifyEmailCode(email: email, code: code);

  @override
  AccountIdentity? takePendingIdentity() => _auth?.takePendingIdentity();

  @override
  String? takePendingError() => _auth?.takePendingError();

  @override
  Future<void> signOut() async => (await _connected).signOut();
}

/// Supabase could not be started (e.g. offline while the page loaded).
class UnreachableAccountAuth implements AccountAuth {
  const UnreachableAccountAuth();

  static const _down =
      AccountAuthException(AccountAuthError.unreachable, 'Sign-in could not be reached. Check your connection and try again.');

  @override
  bool get available => true;

  @override
  ValueListenable<bool> get ready => const AlwaysReady();

  @override
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo}) => Future.error(_down);

  @override
  Future<void> sendEmailCode(String email) => Future.error(_down);

  @override
  Future<AccountIdentity> verifyEmailCode({required String email, required String code}) => Future.error(_down);

  @override
  AccountIdentity? takePendingIdentity() => null;

  @override
  String? takePendingError() => null;

  @override
  Future<void> signOut() async {}
}

/// The app was built without SUPABASE_URL / SUPABASE_ANON_KEY.
class UnavailableAccountAuth implements AccountAuth {
  const UnavailableAccountAuth();

  static const _off = AccountAuthException(AccountAuthError.other, 'Account sign-in is not set up in this build.');

  @override
  bool get available => false;

  @override
  ValueListenable<bool> get ready => const AlwaysReady();

  @override
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo}) => Future.error(_off);

  @override
  Future<void> sendEmailCode(String email) => Future.error(_off);

  @override
  Future<AccountIdentity> verifyEmailCode({required String email, required String code}) => Future.error(_off);

  @override
  AccountIdentity? takePendingIdentity() => null;

  @override
  String? takePendingError() => null;

  @override
  Future<void> signOut() async {}
}
