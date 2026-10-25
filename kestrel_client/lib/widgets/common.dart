import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';

/// Thin flowing lines drawn over the crimson panels (the "need a person"
/// card, the sign-in hero), like flight paths on a route map.
class Waves extends StatelessWidget {
  const Waves({super.key, this.color = const Color(0x2EFFFFFF)});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _WavesPainter(color))));
}

class _WavesPainter extends CustomPainter {
  _WavesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    final w = size.width, h = size.height;
    for (var i = 0; i < 7; i++) {
      final dy = i * h * .05;
      final path = Path()
        ..moveTo(-w * .05, h * .30 + dy)
        ..cubicTo(w * .25, h * .02 + dy, w * .45, h * .80 - dy, w * .70, h * .48 + dy)
        ..cubicTo(w * .85, h * .30 + dy, w * .95, h * .18 + dy, w * 1.05, h * .36 + dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavesPainter old) => old.color != color;
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

/// Shown wherever the app could be mistaken for an airline service.
const disclaimer = 'Research prototype — not an official Kenya Airways service. Synthetic data.';

class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.markSize = 48});
  final double markSize;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Kestrel, disruption assistant',
      header: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KestrelMark(size: markSize),
          const SizedBox(width: K.s3),
          Flexible(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('KESTREL',
                      maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
                      style: t.titleLarge?.copyWith(letterSpacing: 1)),
                  Text('Disruption assistant',
                      maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
                      style: K.label(context).copyWith(color: K.glow, fontSize: 12, letterSpacing: 0.3)),
                ],
              ),
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
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.icon,
    this.height = 56,
    this.expand = true,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  final double height;

  /// Full width (forms) or as wide as the label (cards, headers).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final textStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(color: Colors.white, fontSize: height >= 56 ? 17 : 15);
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
                height: height,
                width: expand ? double.infinity : null,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: expand ? 0 : K.s5),
                  child: Center(
                    widthFactor: expand ? null : 1,
                    child: busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        // With very large text a long label shrinks to fit the
                        // button rather than being cut off.
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: expand ? K.s3 : 0),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (icon != null) ...[
                                  Icon(icon, size: 18, color: Colors.white),
                                  const SizedBox(width: K.s2),
                                ],
                                Text(label, style: textStyle),
                              ]),
                            ),
                          ),
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

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.height = 56,
    this.expand = true,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 20),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: K.textPrimary,
        backgroundColor: K.surface,
        minimumSize: Size(K.touch, height),
        padding: const EdgeInsets.symmetric(horizontal: K.s5),
        side: const BorderSide(color: K.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(K.radius)),
      ),
    );
    return expand ? SizedBox(height: height, width: double.infinity, child: button) : button;
  }
}

/// A text link with an arrow ("View all →"), at least 48 dp tall.
class LinkButton extends StatelessWidget {
  const LinkButton({super.key, required this.label, required this.onPressed, this.icon = Icons.arrow_forward});
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: K.glow,
          minimumSize: const Size(K.touch, K.touch),
          padding: const EdgeInsets.symmetric(horizontal: K.s3),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Icon(icon, size: 18),
        ]),
      );
}

/// Pill / Status. Colour is never the only signal: the word is always shown.
class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});
  final String status;

  static (String, Color) _look(String status) => switch (status) {
        'CANCELLED' || 'DISRUPTED' => ('Cancelled', K.glow),
        'REACCOMMODATED' || 'CONFIRMED' || 'ISSUED' => ('Confirmed', K.teal),
        'ELIGIBLE' => ('Eligible', K.amber),
        'REDEEMED' => ('Redeemed', K.textSecondary),
        'VOID' => ('Void', K.textSecondary),
        'OPEN' => ('Open', K.amber),
        'RESOLVED' => ('Resolved', K.teal),
        _ => (titleCase(status), K.amber),
      };

  static const _padding = 10.0, _dot = 6.0, _gap = 6.0, _border = 1.0;

  /// The width the pill needs to show its whole word at the current text
  /// size, so a table column can be sized to fit it rather than cut it off.
  static double widthFor(BuildContext context, String status) {
    final painter = TextPainter(
      text: TextSpan(text: _look(status).$1.toUpperCase(), style: K.label(context)),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return (painter.width + 2 * (_padding + _border) + _dot + _gap).ceilToDouble() + 2;
  }

  @override
  Widget build(BuildContext context) {
    final (label, color) = _look(status);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: _padding),
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
                width: _dot, height: _dot, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
          const SizedBox(width: _gap),
          Flexible(
            child: Text(label.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: K.label(context).copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// The card container shared by tickets, flights, vouchers and panels.
class KCard extends StatelessWidget {
  const KCard({
    super.key,
    required this.child,
    this.onTap,
    this.highlighted = false,
    this.semanticLabel,
    this.padding = const EdgeInsets.all(K.s5),
    this.color = K.surface,
  });
  final Widget child;
  final VoidCallback? onTap;
  final bool highlighted;
  final String? semanticLabel;
  final EdgeInsets padding;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(K.radiusLg),
        border: Border.all(color: highlighted ? K.glow : K.hairline, width: highlighted ? 1.5 : 1),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: BorderRadius.circular(K.radiusLg), onTap: onTap, child: card),
      ),
    );
  }
}

/// A rounded, tinted square holding an icon (voucher types, triggers, steps).
class IconChip extends StatelessWidget {
  const IconChip(this.icon, {super.key, this.color = K.glow, this.background = K.crimsonSoft, this.size = 44});
  final IconData icon;
  final Color color, background;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size * .3)),
          child: Icon(icon, color: color, size: size * .48),
        ),
      );
}

/// A person's initials in a circle (the signed-in passenger or staff member).
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar(this.text, {super.key, this.size = 40});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: K.elevated, shape: BoxShape.circle),
          child: Text(text,
              style: K.inter(fontSize: size * .36, fontWeight: FontWeight.w700, color: K.textPrimary)),
        ),
      );
}

/// "NBO ●───✈───● MBA" with times, cities and the flight's duration. A
/// cancelled flight gets a dashed crimson line.
class RouteLine extends StatelessWidget {
  const RouteLine({
    super.key,
    required this.origin,
    required this.destination,
    required this.departureLocal,
    required this.arrivalLocal,
    this.cancelled = false,
    this.compact = false,
    this.background = K.surface,
  });
  final String origin, destination;
  final String? departureLocal, arrivalLocal;
  final bool cancelled, compact;

  /// The card colour behind the line, used to cut out the plane icon.
  final Color background;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final plus = dayOffset(departureLocal, arrivalLocal);
    final code = K.inter(
      fontSize: compact ? 16 : 24,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: .2,
    );
    final cityStyle = t.bodySmall?.copyWith(color: K.textSecondary);
    final time = compact ? K.dataMd(context) : K.dataLg(context);
    return Semantics(
      label: 'Departs $origin ${city(origin)} at ${hhmm(departureLocal)} local time, '
          'arrives $destination ${city(destination)} at ${hhmm(arrivalLocal)} local time'
          '${plus.isEmpty ? '' : ', $plus'}${cancelled ? '. Cancelled' : ''}.',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(origin, style: code.copyWith(color: K.glow)),
            if (!compact) Text(city(origin), style: cityStyle),
            SizedBox(height: compact ? 2 : K.s2),
            Text(hhmm(departureLocal), style: time),
          ]),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(K.s3, compact ? 0 : K.s1, K.s3, 0),
              child: Column(children: [
                Text(cancelled ? 'Cancelled' : duration(departureLocal, arrivalLocal),
                    style: K.label(context).copyWith(color: cancelled ? K.glow : K.textSecondary)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 22,
                  child: CustomPaint(
                    painter: _TrackPainter(cancelled: cancelled, background: background),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        color: background,
                        child: Transform.rotate(
                          angle: math.pi / 2,
                          child: Icon(Icons.flight, size: 18, color: cancelled ? K.glow : K.textPrimary),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(destination, style: code.copyWith(color: K.textPrimary)),
            if (!compact) Text(city(destination), style: cityStyle),
            SizedBox(height: compact ? 2 : K.s2),
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic, children: [
              Text(hhmm(arrivalLocal), style: time),
              if (plus.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(plus, style: K.label(context).copyWith(color: K.amber)),
              ],
            ]),
          ]),
        ],
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  _TrackPainter({required this.cancelled, required this.background});
  final bool cancelled;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = cancelled ? K.glow : K.crimson600
      ..strokeWidth = 2;
    const r = 5.0;
    if (cancelled) {
      for (var x = r * 2; x < size.width - r * 2; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, size.width - r * 2), y), line);
      }
    } else {
      canvas.drawLine(Offset(r * 2, y), Offset(size.width - r * 2, y), line);
    }
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = K.glow;
    final fill = Paint()..color = background;
    for (final x in [r + 1, size.width - r - 1]) {
      canvas.drawCircle(Offset(x, y), r, fill);
      canvas.drawCircle(Offset(x, y), r, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) =>
      old.cancelled != cancelled || old.background != background;
}

/// The perforation across a ticket: a dashed line with a notch cut into each
/// edge of the card. [inset] is the card's horizontal padding.
class TicketDivider extends StatelessWidget {
  const TicketDivider({super.key, this.inset = K.s5, this.notchColor = K.base});
  final double inset;

  /// The colour of whatever the card sits on.
  final Color notchColor;

  @override
  Widget build(BuildContext context) {
    Widget notch() => Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(color: notchColor, shape: BoxShape.circle),
        );
    return ExcludeSemantics(
      child: SizedBox(
        height: 20,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: CustomPaint(painter: _DashPainter())),
          Positioned(left: -inset - 11, top: 0, child: notch()),
          Positioned(right: -inset - 11, top: 0, child: notch()),
        ]),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = K.hairline
      ..strokeWidth = 1.5;
    final y = size.height / 2;
    for (var x = 4.0; x < size.width - 4; x += 10) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, size.width - 4), y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: Text(text.toUpperCase(), style: K.label(context)));
}

/// A section heading in sentence case with an optional link on the right
/// ("Flights from Nairobi ........ View all").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      if (action != null) LinkButton(label: action!, onPressed: onAction),
    ]);
  }
}

/// The heading at the top of a section page.
class PageHeading extends StatelessWidget {
  const PageHeading(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: t.headlineSmall?.copyWith(fontSize: 28))),
          if (subtitle != null) ...[
            const SizedBox(height: K.s1),
            Text(subtitle!, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
          ],
        ]),
      ),
      if (trailing != null) ...[const SizedBox(width: K.s3), trailing!],
    ]);
  }
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

/// A short informational banner (e.g. "you're already rebooked").
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.text, this.icon = Icons.info_outline, this.color = K.teal});
  final String text;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(K.s4),
        decoration: BoxDecoration(
          color: color.withAlpha(24),
          borderRadius: BorderRadius.circular(K.radius),
          border: Border.all(color: color.withAlpha(90)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: K.s3),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ]),
      );
}

/// Centred spinner with a label for screen readers.
class Loading extends StatelessWidget {
  const Loading(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(K.s6),
        child: Center(child: Semantics(label: label, child: const CircularProgressIndicator())),
      );
}
