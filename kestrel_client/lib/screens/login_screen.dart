import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../auth/account_auth.dart';
import '../config.dart';
import '../format.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/google_logo.dart';
import '../widgets/otp_boxes.dart';
import '../widgets/public.dart';
import 'staff_loader.dart';

/// M02 / M03 · Sign in (02-SignIn, 02b-SignIn-CodeSent, 15-Phone-SignIn).
/// Three ways in for passengers - Google, an emailed one-time code, or the
/// booking reference and surname as a guest - and the staff key for the
/// disruption desk (FR-09). The code is entered on this same page.
///
/// Google and the email code only switch the page's states for now; they are
/// connected to Supabase Auth in a later phase. Guest and staff sign-in work.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = PublicScope.of(context).mode;
    final body = switch (mode) {
      SignInMode.choose => const _AccountOptions(),
      SignInMode.guest => const _GuestOption(),
      SignInMode.staff => const _StaffForm(),
    };
    return Scaffold(
      backgroundColor: K.base,
      body: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 960) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Expanded(child: _BrandPanel()),
            Expanded(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: K.s6),
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: body),
                  ),
                ),
              ),
            ),
          ]);
        }
        return SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const _BrandBand(),
            Transform.translate(
              offset: const Offset(0, -24),
              child: Container(
                decoration: const BoxDecoration(
                  color: K.base,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(K.s5, K.s5, K.s5, K.s6),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      body,
                      const SizedBox(height: K.s5),
                      Text(disclaimer,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: K.textSecondary)),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Brand: the red panel (laptop) and the red band (phone)
// ---------------------------------------------------------------------------

class _BackToHome extends StatelessWidget {
  const _BackToHome({this.iconOnly = false});
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Color(0x80FFFFFF)),
      minimumSize: const Size(K.touch, K.touch),
      padding: EdgeInsets.symmetric(horizontal: iconOnly ? 0 : K.s4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
    void back() => PublicScope.read(context).goHome();
    return iconOnly
        ? Semantics(
            label: 'Back to home',
            button: true,
            excludeSemantics: true,
            child: OutlinedButton(onPressed: back, style: style, child: const Icon(Icons.arrow_back, size: 20)),
          )
        : OutlinedButton.icon(
            onPressed: back,
            style: style,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to home'),
          );
  }
}

/// The white tile with the crimson plane, on the red brand surfaces.
class _InverseMark extends StatelessWidget {
  const _InverseMark({this.size = 88});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(size * .22),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10))],
          ),
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Icon(Icons.flight, color: K.crimson, size: size * .5),
          ),
        ),
      );
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: K.primaryGradient),
      child: CustomPaint(
        painter: _OrbitsPainter(),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(56, 40, 56, 40),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const _BackToHome(),
                      const Spacer(),
                      const _InverseMark(),
                      const SizedBox(height: K.s6),
                      Semantics(
                        header: true,
                        child: Text('Kestrel',
                            style: t.displaySmall?.copyWith(
                                fontSize: 96, height: 1, fontWeight: FontWeight.w800, letterSpacing: -3, color: Colors.white)),
                      ),
                      const SizedBox(height: K.s4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Text('Disruption recovery for Kenya Airways passengers',
                            style: t.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w400, height: 1.3)),
                      ),
                      const SizedBox(height: K.s5),
                      Container(width: 120, height: 1, color: const Color(0x80FFFFFF)),
                      const SizedBox(height: K.s5),
                      Wrap(spacing: K.s3, runSpacing: K.s3, children: [
                        for (final chip in const ['Rebook in minutes', 'Vouchers issued', 'Policy cited'])
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0x1AFFFFFF),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0x80FFFFFF)),
                            ),
                            child: Text(chip.toUpperCase(),
                                style: K.mono(fontSize: 11.5, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: Colors.white)),
                          ),
                      ]),
                      const Spacer(),
                      Text(disclaimer, style: t.bodySmall?.copyWith(color: Colors.white)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandBand extends StatelessWidget {
  const _BrandBand();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: K.primaryGradient),
      child: CustomPaint(
        painter: _OrbitsPainter(),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(K.s5, K.s4, K.s5, 48),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const _BackToHome(iconOnly: true),
              const SizedBox(height: K.s6),
              Row(children: [
                const _InverseMark(size: 60),
                const SizedBox(width: K.s4),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Semantics(
                      header: true,
                      child: Text('Kestrel',
                          style: t.displaySmall?.copyWith(
                              fontSize: 38, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -1, color: Colors.white)),
                    ),
                    Text('Disruption recovery for Kenya Airways passengers',
                        style: t.bodyMedium?.copyWith(color: Colors.white)),
                  ]),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Faint flight-path circles and lines across the red brand surfaces.
class _OrbitsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x24FFFFFF);
    canvas.drawCircle(Offset(size.width * .78, size.height * .27), size.width * .40, p);
    canvas.drawCircle(Offset(size.width * .78, size.height * .27), size.width * .25, p);
    canvas.drawLine(Offset(0, size.height * .72), Offset(size.width, size.height * .14), p);
    canvas.drawLine(Offset(0, size.height * .86), Offset(size.width, size.height * .52), p);
    final dot = Paint()..color = const Color(0x66FFFFFF);
    canvas.drawCircle(Offset(size.width * .89, size.height * .37), 3, dot);
    canvas.drawCircle(Offset(size.width * .65, size.height * .46), 3, dot);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Account options: Google, email code (inline), guest, staff
// ---------------------------------------------------------------------------

enum _EmailStage { enter, codeSent }

class _AccountOptions extends StatefulWidget {
  const _AccountOptions();

  @override
  State<_AccountOptions> createState() => _AccountOptionsState();
}

class _AccountOptionsState extends State<_AccountOptions> {
  static const _resendSeconds = 60;

  /// Wrong codes allowed before a new code is needed.
  static const _maxAttempts = 5;

  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _emailFocus = FocusNode();
  final _boxes = GlobalKey<OtpBoxesState>();
  _EmailStage _stage = _EmailStage.enter;
  String _code = '';
  int _secondsLeft = 0;
  Timer? _timer;

  bool _googleBusy = false;
  bool _sending = false;
  bool _verifying = false;
  int _wrongCodes = 0;

  /// A problem with the email address or sending the code (under the field).
  String? _emailError;

  /// A problem with the code (under the boxes).
  String? _codeError;

  /// Anything else (e.g. linking refused by the REST tier).
  String? _notice;

  bool get _blocked => _wrongCodes >= _maxAttempts;

  @override
  void initState() {
    super.initState();
    _notice = PublicScope.read(context).takeNotice();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  AccountAuth get _auth => SessionScope.read(context).auth;

  static String _sendFailure(AccountAuthException e) => switch (e.kind) {
        AccountAuthError.rateLimited => 'Too many codes requested. Try again in a minute.',
        AccountAuthError.unreachable => 'We couldn\'t send a code. Check your connection and try again.',
        _ => e.message,
      };

  /// The account is signed in: exchange it for a Kestrel session, or offer
  /// bookings to link.
  Future<void> _finish(AccountIdentity identity) async {
    final session = SessionScope.read(context);
    final public = PublicScope.read(context);
    try {
      final suggestions = await session.signInWithAccount(identity);
      if (suggestions != null) public.showLinkBooking(AccountLink(identity, suggestions));
      // Otherwise SessionGate opens the passenger app.
    } on ApiException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    }
  }

  Future<void> _google() async {
    setState(() {
      _googleBusy = true;
      _notice = null;
    });
    AccountIdentity? identity;
    try {
      identity = await _auth.signInWithGoogle(redirectTo: kIsWeb ? Uri.base.origin : AppConfig.appAuthRedirect);
      if (identity != null) await _finish(identity);
    } on AccountAuthException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } finally {
      // In a browser the page is leaving for Google: keep the spinner.
      if (mounted && (identity != null || _notice != null)) setState(() => _googleBusy = false);
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _secondsLeft = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsLeft = math.max(0, _secondsLeft - 1));
      if (_secondsLeft == 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    setState(() {
      _notice = null;
      _emailError = null;
    });
    if (_sending || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _sending = true);
    try {
      await _auth.sendEmailCode(_email.text.trim());
      if (!mounted) return;
      setState(() {
        _stage = _EmailStage.codeSent;
        _code = '';
        _wrongCodes = 0;
        _codeError = null;
      });
      _startCountdown();
    } on AccountAuthException catch (e) {
      if (mounted) setState(() => _emailError = _sendFailure(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// A new code, after the 60-second wait: the tries start again.
  Future<void> _resend() async {
    if (_secondsLeft > 0 || _sending) return;
    setState(() {
      _sending = true;
      _codeError = null;
      _notice = null;
    });
    try {
      await _auth.sendEmailCode(_email.text.trim());
      if (!mounted) return;
      _boxes.currentState?.clear();
      setState(() {
        _code = '';
        _wrongCodes = 0;
      });
      _startCountdown();
    } on AccountAuthException catch (e) {
      if (mounted) setState(() => _codeError = _sendFailure(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Back to an empty email field; the code already sent is dropped.
  void _change() {
    _timer?.cancel();
    _email.clear();
    setState(() {
      _stage = _EmailStage.enter;
      _code = '';
      _secondsLeft = 0;
      _wrongCodes = 0;
      _codeError = null;
      _emailError = null;
      _notice = null;
    });
    _emailFocus.requestFocus();
  }

  Future<void> _verify() async {
    if (_code.length < OtpBoxes.length || _verifying || _blocked) return;
    final code = _code;
    setState(() {
      _verifying = true;
      _codeError = null;
      _notice = null;
    });
    try {
      final identity = await _auth.verifyEmailCode(email: _email.text.trim(), code: code);
      await _finish(identity);
    } on AccountAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.kind) {
          case AccountAuthError.expiredCode:
            _codeError = 'This code has expired. Send a new one.';
          case AccountAuthError.invalidCode:
            _wrongCodes++;
            final left = _maxAttempts - _wrongCodes;
            _codeError = left <= 0
                ? 'Too many wrong codes. Send a new code to try again.'
                : 'That code isn\'t right. $left ${left == 1 ? 'try' : 'tries'} left.';
          default:
            _codeError = e.message;
        }
      });
      _boxes.currentState?.clear();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  // Supabase starts in the background (main.dart): until it is ready the
  // Google and email buttons show, disabled, with a line saying why.
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: _auth.ready,
        builder: (context, ready, _) => _options(context, ready: ready),
      );

  Widget _options(BuildContext context, {required bool ready}) {
    final t = Theme.of(context).textTheme;
    final public = PublicScope.read(context);
    final sent = _stage == _EmailStage.codeSent;
    final small = t.bodySmall?.copyWith(color: K.textSecondary);
    final accounts = _auth.available;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(header: true, child: Text('Sign in to Kestrel', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
      const SizedBox(height: K.s1),
      Text(
        accounts
            ? 'New here? Signing in creates your account.'
            : 'Use your booking reference and the surname on the ticket.',
        style: t.bodyMedium?.copyWith(color: K.textSecondary),
      ),
      const SizedBox(height: K.s5),
      // Google and email codes need the Supabase settings in the build.
      if (accounts) ...[
      Semantics(
        button: true,
        enabled: !_googleBusy && ready,
        label: _googleBusy
            ? 'Continue with Google, working'
            : ready
                ? 'Continue with Google'
                : 'Continue with Google, connecting',
        excludeSemantics: true,
        child: OutlinedButton(
          onPressed: _googleBusy || !ready ? null : _google,
          style: OutlinedButton.styleFrom(
            foregroundColor: K.textPrimary,
            backgroundColor: K.surface,
            disabledForegroundColor: K.textSecondary,
            minimumSize: const Size(K.touch, 52),
            side: const BorderSide(color: K.hairline),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: t.labelLarge,
          ),
          child: _googleBusy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  GoogleLogo(size: 18),
                  SizedBox(width: K.s3),
                  Flexible(child: Text('Continue with Google')),
                ]),
        ),
      ),
      if (!ready) ...[
        const SizedBox(height: K.s3),
        Semantics(
          liveRegion: true,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: K.s2),
            Flexible(child: Text('Connecting to the sign-in service…', style: small)),
          ]),
        ),
      ],
      const SizedBox(height: K.s4),
      ExcludeSemantics(
        child: Row(children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: K.s3),
            child: Text('OR', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.textSecondary)),
          ),
          const Expanded(child: Divider()),
        ]),
      ),
      const SizedBox(height: K.s4),
      Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionLabel('Email'),
          const SizedBox(height: K.s2),
          TextFormField(
            controller: _email,
            focusNode: _emailFocus,
            readOnly: sent || _sending,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              hintText: 'you@example.com',
              errorText: _emailError,
              errorMaxLines: 3,
              suffixIcon: sent
                  ? TextButton(
                      onPressed: _change,
                      style: TextButton.styleFrom(foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
                      child: const Text('Change'),
                    )
                  : null,
            ),
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return 'Enter your email address.';
              return isValidEmail(s) ? null : 'Enter a valid email address.';
            },
            onFieldSubmitted: (_) => sent || !ready ? null : _sendCode(),
          ),
        ]),
      ),
      const SizedBox(height: K.s3),
      AnimatedSize(
        duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: sent
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Semantics(
                  liveRegion: true,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: K.s1,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check, size: 16, color: K.teal),
                        const SizedBox(width: K.s2),
                        Flexible(
                          child: Text('Code sent to ${maskEmail(_email.text)}',
                              style: t.bodySmall?.copyWith(color: K.teal)),
                        ),
                      ]),
                      _secondsLeft > 0
                          ? Semantics(
                              label: 'You can ask for a new code in $_secondsLeft seconds',
                              excludeSemantics: true,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                child: Text.rich(TextSpan(children: [
                                  TextSpan(text: 'Resend in ', style: small),
                                  TextSpan(
                                    text: '${_secondsLeft ~/ 60}:${(_secondsLeft % 60).toString().padLeft(2, '0')}',
                                    style: K.mono(fontSize: 12.5, color: K.textSecondary),
                                  ),
                                ])),
                              ),
                            )
                          : TextButton(
                              onPressed: _resend,
                              style: TextButton.styleFrom(foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
                              child: const Text('Resend code'),
                            ),
                    ],
                  ),
                ),
                const SizedBox(height: K.s2),
                const SectionLabel('Verification code'),
                const SizedBox(height: K.s2),
                OtpBoxes(
                  key: _boxes,
                  enabled: !_blocked && !_verifying,
                  error: _codeError != null,
                  onChanged: (c) => setState(() => _code = c),
                  // The sixth digit submits by itself.
                  onCompleted: (_) => _verify(),
                ),
                if (_codeError != null) ...[
                  const SizedBox(height: K.s2),
                  Semantics(
                    liveRegion: true,
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.error_outline, size: 16, color: K.glow),
                      const SizedBox(width: K.s2),
                      Expanded(child: Text(_codeError!, style: t.bodySmall?.copyWith(color: K.glow))),
                    ]),
                  ),
                ],
                const SizedBox(height: K.s4),
                PrimaryButton(
                  label: 'Verify and sign in',
                  busy: _verifying,
                  onPressed: _code.length == OtpBoxes.length && !_blocked ? _verify : null,
                  height: 52,
                ),
                const SizedBox(height: K.s3),
                Text('The code expires in 10 minutes. Not there? Check your spam folder.', style: small),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                PrimaryButton(
                  label: 'Send verification code',
                  icon: Icons.mail_outline,
                  busy: _sending,
                  onPressed: ready ? _sendCode : null,
                  height: 52,
                ),
                const SizedBox(height: K.s3),
                Text('We\'ll email you a 6-digit code. No password needed.', style: small),
              ]),
      ),
      ],
      if (_notice != null) ...[
        const SizedBox(height: K.s4),
        ErrorNotice(message: _notice!),
      ],
      const SizedBox(height: K.s5),
      Semantics(
        button: true,
        label: 'Only have a booking reference? Continue as guest, no account needed.',
        excludeSemantics: true,
        child: Material(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(K.radius),
            onTap: () => public.signIn(SignInMode.guest),
            child: Container(
              padding: const EdgeInsets.all(K.s4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(K.radius),
                border: Border.all(color: K.hairline),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.confirmation_number_outlined, color: K.glow, size: 20),
                const SizedBox(width: K.s3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Only have a booking reference?', style: t.titleMedium?.copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text('Use it with your surname — no account needed.', style: t.bodySmall?.copyWith(color: K.textSecondary)),
                    const SizedBox(height: K.s2),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Text('Continue as guest', style: t.labelLarge?.copyWith(color: K.glow))),
                      const SizedBox(width: K.s1),
                      const Icon(Icons.arrow_forward, size: 16, color: K.glow),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: K.s3),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => public.signIn(SignInMode.staff),
          style: TextButton.styleFrom(
            foregroundColor: K.textSecondary,
            minimumSize: const Size(K.touch, K.touch),
            padding: EdgeInsets.zero,
            textStyle: t.bodySmall?.copyWith(decoration: TextDecoration.underline),
          ),
          child: const Text('Disruption desk staff sign in here'),
        ),
      ),
    ]);
  }
}

/// A link back to the account options, above the guest and staff forms.
class _OtherWays extends StatelessWidget {
  const _OtherWays();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => PublicScope.read(context).signIn(),
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Other ways to sign in'),
          style: TextButton.styleFrom(
            foregroundColor: K.textSecondary,
            minimumSize: const Size(K.touch, K.touch),
            padding: EdgeInsets.zero,
          ),
        ),
      );
}

class _GuestOption extends StatelessWidget {
  const _GuestOption();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _OtherWays(),
      const SizedBox(height: K.s4),
      Semantics(header: true, child: Text('Find your booking', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
      const SizedBox(height: K.s1),
      Text('Your booking reference and the surname on the ticket — no account needed.',
          style: t.bodyMedium?.copyWith(color: K.textSecondary)),
      const SizedBox(height: K.s5),
      const GuestBookingForm(autofocus: true),
      const SizedBox(height: K.s4),
      Row(children: [
        const Icon(Icons.lock_outline, size: 16, color: K.textSecondary),
        const SizedBox(width: K.s2),
        Expanded(
          child: Text('Your session ends after 15 minutes. Nothing is saved on this device.',
              style: t.bodySmall?.copyWith(color: K.textSecondary)),
        ),
      ]),
    ]);
  }
}

class _StaffForm extends StatefulWidget {
  const _StaffForm();

  @override
  State<_StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends State<_StaffForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _key = TextEditingController();
  final _keyFocus = FocusNode();
  bool _busy = false;
  bool _showKey = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _key.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    // The desk's code downloads while the key is checked.
    loadStaffDesk().ignore();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionScope.read(context).signInStaff(_name.text, _key.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _OtherWays(),
        const SizedBox(height: K.s4),
        Semantics(header: true, child: Text('Disruption desk', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
        const SizedBox(height: K.s1),
        Text('For Kenya Airways staff handling cases the assistant handed over.',
            style: t.bodyMedium?.copyWith(color: K.textSecondary)),
        const SizedBox(height: K.s5),
        const SectionLabel('Your name'),
        const SizedBox(height: K.s2),
        TextFormField(
          controller: _name,
          enabled: !_busy,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            hintText: 'Recorded on the cases you resolve',
            counterText: '',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your name.' : null,
          onFieldSubmitted: (_) => _keyFocus.requestFocus(),
        ),
        const SizedBox(height: K.s4),
        const SectionLabel('Staff key'),
        const SizedBox(height: K.s2),
        TextFormField(
          controller: _key,
          focusNode: _keyFocus,
          enabled: !_busy,
          obscureText: !_showKey,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'From your team lead',
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Hide key' : 'Show key',
              icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the staff key.' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: K.s4),
          ErrorNotice(message: _error!),
        ],
        const SizedBox(height: K.s5),
        PrimaryButton(label: 'Open the desk', busy: _busy, onPressed: _submit),
        const SizedBox(height: K.s4),
        Row(children: [
          const Icon(Icons.lock_outline, size: 16, color: K.textSecondary),
          const SizedBox(width: K.s2),
          Expanded(
            child: Text('The key is kept in memory for this visit only.',
                style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ),
        ]),
      ]),
    );
  }
}
