import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';

/// Backdrop / Mobile: near-black base, crimson glow, flight-path arcs and a
/// vignette (kestrel-ui-design-system.md, "How the backdrop is built"). The
/// aircraft silhouette is omitted until the vector asset is exported.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.6, -0.35),
          radius: 1.1,
          colors: [Color(0x55A81030), K.void_],
          stops: [0, 0.7],
        ),
      ),
      child: CustomPaint(
        painter: _ArcsPainter(),
        child: SafeArea(child: child),
      ),
    );
  }
}

class _ArcsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final arcs = [
      (const Color(0x4DFF2E55), Rect.fromLTWH(-size.width * .3, size.height * .02, size.width * 1.6, size.height * .5)),
      (const Color(0x2EFF2E55), Rect.fromLTWH(-size.width * .5, size.height * .55, size.width * 2.0, size.height * .9)),
    ];
    for (final (color, rect) in arcs) {
      paint.color = color;
      canvas.drawArc(rect, math.pi * 1.05, math.pi * .9, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Avatar / Kestrel and Brand / Kestrel Lockup.
class KestrelMark extends StatelessWidget {
  const KestrelMark({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: K.primaryGradient,
          boxShadow: [BoxShadow(color: Color(0x66FF2E55), blurRadius: 16)],
        ),
        child: Icon(Icons.flight, size: size * .5, color: Colors.white),
      ),
    );
  }
}

class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Kestrel, Kenya Airways',
      header: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const KestrelMark(size: 48),
          const SizedBox(width: K.s3),
          ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('KESTREL', style: t.titleLarge?.copyWith(letterSpacing: 1)),
                Text('KENYA AIRWAYS',
                    style: K.label(context).copyWith(color: K.glow, fontSize: 13, letterSpacing: 1.6)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Button / Primary: crimson gradient, 56 dp, with a busy state that keeps
/// its size (no layout jump) and tells screen readers it is working.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: busy ? '$label, working' : label,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled || busy ? 1 : .5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: K.primaryGradient,
            borderRadius: BorderRadius.circular(K.radius),
            boxShadow: enabled
                ? const [BoxShadow(color: Color(0x55FF2E55), blurRadius: 24, offset: Offset(0, 6))]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(K.radius),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: 56,
                width: double.infinity,
                child: Center(
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                        )
                      : Text(label,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(color: Colors.white, fontSize: 17)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: K.textPrimary,
          side: const BorderSide(color: K.hairline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radius)),
        ),
      ),
    );
  }
}

/// Pill / Status. Colour is never the only signal: the word is always shown.
class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'CANCELLED' || 'DISRUPTED' => ('Cancelled', K.glow),
      'REACCOMMODATED' || 'CONFIRMED' || 'ISSUED' => ('Confirmed', K.teal),
      'ELIGIBLE' => ('Eligible', K.amber),
      'REDEEMED' => ('Redeemed', K.textSecondary),
      'VOID' => ('Void', K.textSecondary),
      'OPEN' => ('Open', K.amber),
      'RESOLVED' => ('Resolved', K.teal),
      _ => (titleCase(status), K.amber),
    };
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: color.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Container(
                width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 6),
          Text(label.toUpperCase(), style: K.label(context).copyWith(color: color)),
        ],
      ),
    );
  }
}

/// The 326-wide card container shared by booking, flight and voucher cards.
class KCard extends StatelessWidget {
  const KCard({super.key, required this.child, this.onTap, this.highlighted = false, this.semanticLabel});
  final Widget child;
  final VoidCallback? onTap;
  final bool highlighted;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: K.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: highlighted ? K.glow : K.hairline, width: highlighted ? 1.5 : 1),
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: BorderRadius.circular(22), onTap: onTap, child: card),
      ),
    );
  }
}

/// "DEP 22:45 NBO ---- 9h 25m ---- 06:10 AMS +1 day".
class FlightLeg extends StatelessWidget {
  const FlightLeg({
    super.key,
    required this.origin,
    required this.destination,
    required this.departureLocal,
    required this.arrivalLocal,
    this.originNote,
  });
  final String origin, destination;
  final String? departureLocal, arrivalLocal, originNote;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final small = t.bodySmall?.copyWith(color: K.textSecondary);
    final plus = dayOffset(departureLocal, arrivalLocal);
    return Semantics(
      label: 'Departs $origin ${city(origin)} at ${hhmm(departureLocal)} local time, '
          'arrives $destination ${city(destination)} at ${hhmm(arrivalLocal)} local time'
          '${plus.isEmpty ? '' : ', $plus'}.',
      excludeSemantics: true,
      child: Row(
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(hhmm(departureLocal), style: K.dataLg(context)),
            Text('$origin ${originNote ?? ''}'.trim(), style: small),
          ]),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: K.s3),
              child: Column(children: [
                Container(height: 1, color: K.crimson600),
                const SizedBox(height: 6),
                Text(duration(departureLocal, arrivalLocal),
                    style: K.label(context), textAlign: TextAlign.center),
              ]),
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(hhmm(arrivalLocal), style: K.dataLg(context)),
            Text('$destination ${plus.isEmpty ? '' : plus}'.trim(), style: small),
          ]),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: Text(text.toUpperCase(), style: K.label(context)));
}

/// Inline error with a recovery action, announced to screen readers.
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(K.s4),
        decoration: BoxDecoration(
          color: K.glow.withAlpha(20),
          borderRadius: BorderRadius.circular(K.radius),
          border: Border.all(color: K.glow.withAlpha(90)),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline, color: K.glow),
          const SizedBox(width: K.s3),
          Expanded(child: Text(message, style: Theme.of(context).textTheme.bodyMedium)),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                  foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
              child: const Text('Retry'),
            ),
        ]),
      ),
    );
  }
}
