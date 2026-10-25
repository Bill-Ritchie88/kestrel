import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';

/// A friendly full-card explanation of something that went wrong, with the
/// way forward as buttons (session expired, assistant busy, seat taken). The
/// status code is drawn large and faint as decoration only.
class SystemStateCard extends StatelessWidget {
  const SystemStateCard({
    super.key,
    required this.code,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.actions,
    this.compact = false,
  });

  /// Session ended (401). Both ways back in are offered.
  factory SystemStateCard.sessionExpired({required VoidCallback onSignIn, required VoidCallback onBooking}) =>
      SystemStateCard(
        code: '401',
        icon: Icons.lock_outline,
        iconColor: K.amber,
        title: 'Your session has expired',
        body: 'For your security we sign you out 15 minutes after you sign in. Sign in again to pick up '
            'where you left off: your booking, any rebooking you confirmed and your vouchers are saved.',
        actions: [
          PrimaryButton(label: 'Sign in again', onPressed: onSignIn, height: 48, expand: false),
          SecondaryButton(label: 'Use booking reference', onPressed: onBooking, height: 48, expand: false),
        ],
      );

  /// The agent service is down or overloaded (503/504). Everything else in
  /// the app still works.
  factory SystemStateCard.assistantBusy({
    VoidCallback? onRetry,
    required VoidCallback onTrip,
    required VoidCallback onPerson,
  }) =>
      SystemStateCard(
        code: '503',
        icon: Icons.sync,
        iconColor: K.sky,
        title: 'The assistant is busy right now',
        body: 'Rebooking, vouchers and your trip still work. Try the assistant again in a minute, or talk to '
            'a person.',
        compact: true,
        actions: [
          if (onRetry != null) PrimaryButton(label: 'Try again', onPressed: onRetry, height: 44, expand: false),
          SecondaryButton(label: 'Back to my trip', onPressed: onTrip, height: 44, expand: false),
          SecondaryButton(label: 'Talk to a person', onPressed: onPerson, height: 44, expand: false),
        ],
      );

  /// Rebooking refused because the last seat went first (409).
  factory SystemStateCard.seatTaken({required VoidCallback onChooseAnother, VoidCallback? onPerson}) =>
      SystemStateCard(
        code: '409',
        icon: Icons.warning_amber_rounded,
        iconColor: K.glow,
        title: 'That seat was just taken',
        body: 'Someone confirmed the last free seat in your cabin on this flight a moment before you. '
            'Nothing was charged. Choose another flight and we\'ll hold a seat on that one.',
        actions: [
          PrimaryButton(label: 'Choose another flight', onPressed: onChooseAnother, height: 48, expand: false),
          if (onPerson != null)
            SecondaryButton(label: 'Talk to a person', onPressed: onPerson, height: 48, expand: false),
        ],
      );

  final String code;
  final IconData icon;
  final Color iconColor;
  final String title, body;
  final List<Widget> actions;

  /// Smaller, for use inside the chat.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pad = compact ? K.s5 : K.s6 + K.s2;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
        ),
        child: Stack(children: [
          Positioned(
            right: -8,
            top: -24,
            child: ExcludeSemantics(
              child: Text(code,
                  style: K.mono(
                      fontSize: compact ? 96 : 140, fontWeight: FontWeight.w800, color: const Color(0x0DFFFFFF))),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(pad),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IconChip(icon, color: iconColor, background: K.elevated, size: compact ? 44 : 56),
              SizedBox(height: compact ? K.s4 : K.s5),
              Semantics(
                header: true,
                child: Text(title, style: (compact ? t.titleLarge : t.headlineSmall)?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: K.s3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(body, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
              ),
              SizedBox(height: compact ? K.s4 : K.s5),
              Wrap(spacing: K.s3, runSpacing: K.s3, children: actions),
            ]),
          ),
        ]),
      ),
    );
  }
}
