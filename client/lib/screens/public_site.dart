import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../auth/account_auth.dart';
import '../auth/supabase_account_auth.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/public.dart';
import '../widgets/system_state.dart';
import 'help_screen.dart';
import 'home_screen.dart';
import 'link_booking_screen.dart';
import 'login_screen.dart';

/// What someone sees when nobody is signed in: Home, Help, sign-in, the
/// Link booking page, or the "session expired" page after a 401.
///
/// It also finishes a Google sign-in: the browser comes back from Google to
/// the app's address, Supabase has the account, and here it is exchanged for
/// a Kestrel session (or the Link booking page).
class PublicSite extends StatefulWidget {
  const PublicSite({super.key});

  @override
  State<PublicSite> createState() => _PublicSiteState();
}

class _PublicSiteState extends State<PublicSite> {
  bool _finishing = false;
  late final AccountAuth _auth = SessionScope.read(context).auth;

  @override
  void initState() {
    super.initState();
    if (_auth.ready.value) {
      _takePending();
    } else {
      // Supabase is still starting in the background. Back from Google, say
      // so at once rather than flashing Home first.
      _finishing = returningFromAccountSignIn();
      _auth.ready.addListener(_onReady);
    }
  }

  void _onReady() {
    if (!_auth.ready.value) return;
    _auth.ready.removeListener(_onReady);
    if (!mounted) return;
    setState(() {
      _finishing = false;
      _takePending();
    });
  }

  @override
  void dispose() {
    _auth.ready.removeListener(_onReady);
    super.dispose();
  }

  void _takePending() {
    final auth = _auth;
    final error = auth.takePendingError();
    if (error != null) {
      // Back from Google without an account: the sign-in page says why.
      final public = PublicScope.read(context);
      public.notice = error;
      public.page = PublicPage.signIn;
      public.mode = SignInMode.choose;
    }
    final identity = auth.takePendingIdentity();
    if (identity != null) {
      _finishing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final public = PublicScope.read(context);
        try {
          final suggestions = await SessionScope.read(context).signInWithAccount(identity);
          if (suggestions != null) public.showLinkBooking(AccountLink(identity, suggestions));
        } on ApiException catch (e) {
          public.notice = 'Signing in with Google didn\'t finish: ${e.message}';
          public.signIn();
        } finally {
          if (mounted) setState(() => _finishing = false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_finishing) {
      return const Scaffold(backgroundColor: K.base, body: Loading('Signing you in'));
    }
    final public = PublicScope.of(context);
    return switch (public.page) {
      PublicPage.home => const HomeScreen(),
      PublicPage.help => const PublicHelpScreen(),
      PublicPage.signIn => const LoginScreen(),
      PublicPage.sessionExpired => const _SessionExpiredScreen(),
      PublicPage.linkBooking => public.pendingLink == null
          ? const LoginScreen()
          : LinkBookingScreen(key: ObjectKey(public.pendingLink), link: public.pendingLink!),
    };
  }
}

/// 401 (13-NotFound, "Your session has expired"): both ways back in.
class _SessionExpiredScreen extends StatelessWidget {
  const _SessionExpiredScreen();

  @override
  Widget build(BuildContext context) {
    final public = PublicScope.read(context);
    return Scaffold(
      backgroundColor: K.base,
      body: Column(children: [
        const PublicHeader(),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(K.s5),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SystemStateCard.sessionExpired(
                  onSignIn: () => public.signIn(),
                  onBooking: () => public.signIn(SignInMode.guest),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
