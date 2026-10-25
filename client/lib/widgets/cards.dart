import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/recommend.dart';
import '../theme.dart';
import 'common.dart';

// ---------------------------------------------------------------------------
// Booking and flights (M05, M09, M11, M12)
// ---------------------------------------------------------------------------

/// The passenger's trip as a ticket: the cancelled flight, or the recovery
/// flight once rebooked, with the booking details below the perforation.
class TripTicket extends StatelessWidget {
  const TripTicket({super.key, required this.booking, this.compact = false, this.notchColor = K.base});
  final Booking booking;
  final bool compact;
  final Color notchColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = booking.original;
    final current = booking.current;
    final rebooked = booking.isRebooked && current != null;
    final shown = rebooked ? current : f;
    final reason = reasonText[f.disruptionReason];
    final pad = compact ? K.s4 : K.s5;
    final name = '${booking.firstName} ${booking.lastName}'.trim();
    final small = t.bodySmall?.copyWith(color: K.textSecondary);
    return KCard(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconChip(rebooked ? Icons.airplane_ticket_outlined : Icons.flight_takeoff,
                size: compact ? 36 : 44),
            const SizedBox(width: K.s3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${shown.number} · ${dayLabel(shown.departureLocal)}', style: t.titleMedium),
                Text(
                  rebooked
                      ? 'Your new flight'
                      : booking.isDisrupted
                          ? 'Your original flight'
                          : 'Your flight',
                  style: small,
                ),
              ]),
            ),
            StatusPill(rebooked ? 'REACCOMMODATED' : (f.status ?? booking.status)),
          ]),
          SizedBox(height: pad),
          RouteLine(
            origin: f.origin,
            destination: f.destination,
            departureLocal: shown.departureLocal,
            arrivalLocal: shown.arrivalLocal,
            cancelled: !rebooked && booking.isDisrupted,
            compact: compact,
          ),
          const SizedBox(height: K.s3),
          TicketDivider(inset: pad, notchColor: notchColor),
          const SizedBox(height: K.s3),
          Wrap(spacing: K.s5, runSpacing: K.s3, children: [
            if (!compact && name.isNotEmpty) _Meta('Passenger', name),
            if (!compact) _Meta('Booking', booking.pnr),
            _Meta('Cabin', titleCase(booking.cabin)),
            if (rebooked) _Meta('Seat', booking.seat ?? '-') else _Meta('Rewards', titleCase(booking.tier)),
          ]),
          if (!rebooked && booking.isDisrupted && reason != null) ...[
            const SizedBox(height: K.s3),
            Text('Cancelled because of $reason.', style: small),
          ],
          if (rebooked) ...[
            const SizedBox(height: K.s3),
            Text.rich(
              TextSpan(style: small, children: [
                const TextSpan(text: 'Replaces '),
                TextSpan(text: f.number, style: const TextStyle(decoration: TextDecoration.lineThrough)),
                TextSpan(text: reason == null ? ', cancelled.' : ', cancelled because of $reason.'),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 96),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: K.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: K.dataMd(context).copyWith(fontWeight: FontWeight.w600)),
        ]),
      );
}

/// The crimson block on the left of a flight row, in place of an airline
/// logo: the flight number.
class _FlightBadge extends StatelessWidget {
  const _FlightBadge(this.number);
  final String number;

  @override
  Widget build(BuildContext context) => Container(
        width: 92,
        height: 76,
        decoration: BoxDecoration(gradient: K.primaryGradient, borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Transform.rotate(angle: math.pi / 4, child: const Icon(Icons.flight, color: Colors.white, size: 20)),
          const SizedBox(height: 4),
          Text(number, style: K.inter(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ]),
      );
}

/// "Kestrel recommends" (My trip): the best next step, written from the
/// trip by `recommend()` - no model - with one primary action.
class RecommendCard extends StatelessWidget {
  const RecommendCard({super.key, required this.recommendation, required this.onAction, this.busy = false});
  final Recommendation recommendation;
  final VoidCallback onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return KCard(
      highlighted: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const KestrelMark(size: 30),
          const SizedBox(width: K.s3),
          Flexible(
            child: Semantics(
              header: true,
              child: Text('KESTREL RECOMMENDS', style: K.label(context).copyWith(color: K.glow)),
            ),
          ),
        ]),
        const SizedBox(height: K.s3),
        Text(recommendation.text, style: t.bodyLarge),
        const SizedBox(height: K.s4),
        PrimaryButton(
          label: recommendation.actionLabel,
          busy: busy,
          onPressed: onAction,
          height: 48,
          expand: false,
        ),
      ]),
    );
  }
}

/// How each server badge reads, and its colour. The words carry the meaning;
/// the colour only repeats it.
(String, Color) badgeLook(String badge) => switch (badge) {
      'EARLIEST_ARRIVAL' => ('EARLIEST ARRIVAL', K.glow),
      'MOST_SEATS' => ('MOST SEATS', K.teal),
      'SAME_DAY' => ('SAME DAY', K.teal),
      'NEXT_DAY_HOTEL' => ('HOTEL INCLUDED', K.sky),
      'ALMOST_FULL' => ('ALMOST FULL', K.amber),
      _ => (badge.replaceAll('_', ' '), K.textSecondary),
    };

class _Badges extends StatelessWidget {
  const _Badges(this.badges);
  final List<String> badges;

  @override
  Widget build(BuildContext context) => Wrap(spacing: K.s2, runSpacing: K.s1, children: [
        for (final b in badges)
          Builder(builder: (context) {
            final (text, color) = badgeLook(b);
            return Text(text, style: K.label(context).copyWith(color: color));
          }),
      ]);
}

/// One recovery flight (M09). The whole card is the touch target. In a wide
/// column it is a row, as in a flight search; on a phone it stacks. Below
/// it, outside the touch target, "Why this flight?" opens the reasons.
class FlightOptionCard extends StatelessWidget {
  const FlightOptionCard({
    super.key,
    required this.flight,
    this.onSelect,
    this.recommended = false,
  });
  final Flight flight;
  final VoidCallback? onSelect;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final seats = flight.seatsLeft;
    final seatColor = seats <= 3 ? K.amber : K.textSecondary;
    final seatsText = '$seats ${seats == 1 ? 'seat' : 'seats'} left · ${titleCase(flight.cabin ?? '')}';
    // The server's badges; without them (an older REST tier) the first
    // flight is still marked as the earliest arrival.
    final badges = flight.badges.isNotEmpty
        ? flight.badges
        : [if (recommended) 'EARLIEST_ARRIVAL'];
    final tag = _Badges(badges);
    final route = RouteLine(
      origin: flight.origin,
      destination: flight.destination,
      departureLocal: flight.departureLocal,
      arrivalLocal: flight.arrivalLocal,
      compact: true,
    );
    final meta = Wrap(spacing: K.s3, runSpacing: K.s1, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(dayLabel(flight.departureLocal), style: t.bodySmall?.copyWith(color: K.textSecondary)),
      Text('Same route', style: t.bodySmall?.copyWith(color: K.teal, fontWeight: FontWeight.w600)),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.event_seat, size: 15, color: seatColor),
        const SizedBox(width: K.s1),
        Text(seatsText, style: t.bodySmall?.copyWith(color: seatColor)),
      ]),
    ]);
    final card = KCard(
      highlighted: recommended,
      onTap: onSelect,
      padding: const EdgeInsets.all(K.s4),
      semanticLabel: '${badges.map((b) => '${titleCase(badgeLook(b).$1)}. ').join()}'
          'Flight ${flight.number}, ${dayLabel(flight.departureLocal)}, '
          'departs ${hhmm(flight.departureLocal)}, arrives ${hhmm(flight.arrivalLocal)}, '
          '$seats ${seats == 1 ? 'seat' : 'seats'} left in ${titleCase(flight.cabin ?? '')}. '
          'Double tap to choose.',
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= 560) {
            return Row(children: [
              _FlightBadge(flight.number),
              const SizedBox(width: K.s4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (badges.isNotEmpty) ...[tag, const SizedBox(height: K.s1)],
                  route,
                  const SizedBox(height: K.s2),
                  meta,
                ]),
              ),
              if (onSelect != null) ...[
                const SizedBox(width: K.s5),
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: K.s5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      gradient: K.primaryGradient, borderRadius: BorderRadius.circular(12)),
                  child: Text('Choose',
                      style: t.labelLarge?.copyWith(color: Colors.white)),
                ),
              ],
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${flight.number} · ${dayLabel(flight.departureLocal)}', style: t.titleMedium),
            if (badges.isNotEmpty) ...[const SizedBox(height: K.s1), tag],
            const SizedBox(height: K.s3),
            route,
            const SizedBox(height: K.s3),
            Row(children: [
              Icon(Icons.event_seat, size: 16, color: seatColor),
              const SizedBox(width: K.s1),
              Expanded(child: Text(seatsText, style: t.bodySmall?.copyWith(color: seatColor))),
              if (onSelect != null) const Icon(Icons.chevron_right, color: K.textSecondary),
            ]),
          ]);
        }),
      ),
    );
    if (flight.reasons.isEmpty) return card;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      card,
      WhyThisFlight(reasons: flight.reasons),
    ]);
  }
}

/// "Why this flight?": the plain reasons the REST tier gave, opened on
/// request so the list of flights stays short.
class WhyThisFlight extends StatefulWidget {
  const WhyThisFlight({super.key, required this.reasons});
  final List<String> reasons;

  @override
  State<WhyThisFlight> createState() => _WhyThisFlightState();
}

class _WhyThisFlightState extends State<WhyThisFlight> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        button: true,
        expanded: _open,
        child: TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
          label: const Text('Why this flight?'),
          style: TextButton.styleFrom(
            foregroundColor: K.textSecondary,
            minimumSize: const Size(K.touch, K.touch),
            padding: const EdgeInsets.symmetric(horizontal: K.s2),
          ),
        ),
      ),
      AnimatedSize(
        duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
        alignment: Alignment.topCenter,
        child: _open
            ? Padding(
                padding: const EdgeInsets.fromLTRB(K.s3, 0, K.s3, K.s2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final r in widget.reasons)
                    Padding(
                      padding: const EdgeInsets.only(bottom: K.s2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 3),
                          child: Icon(Icons.check, size: 15, color: K.teal),
                        ),
                        const SizedBox(width: K.s2),
                        Expanded(child: Text(r, style: t.bodySmall?.copyWith(color: K.textPrimary))),
                      ]),
                    ),
                ]),
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Entitlements and vouchers (M13, M14)
// ---------------------------------------------------------------------------

IconData entitlementIcon(String type) => switch (type) {
      'MEAL' => Icons.restaurant,
      'HOTEL' => Icons.hotel,
      'TRANSPORT' => Icons.directions_car,
      'ASANTE_POINTS' => Icons.stars,
      'CASH_COMPENSATION' => Icons.payments,
      _ => Icons.card_giftcard,
    };

String entitlementName(String type) => switch (type) {
      'MEAL' => 'Meal voucher',
      'HOTEL' => 'Hotel accommodation',
      'TRANSPORT' => 'Airport transfer',
      'ASANTE_POINTS' => 'Asante Rewards points',
      'CASH_COMPENSATION' => 'Compensation',
      _ => titleCase(type.replaceAll('_', ' ')),
    };

/// "2 × KES 2,500", "3,000 points", "1 night".
String entitlementValue(
    {required String type, int quantity = 1, double? amount, String? currency, int? points}) {
  if (points != null) return '${money(points.toDouble(), null)} points';
  if (amount != null) {
    final each = money(amount, currency);
    return quantity > 1 ? '$quantity × $each' : each;
  }
  return switch (type) {
    'HOTEL' => '$quantity ${quantity == 1 ? 'night' : 'nights'}',
    'TRANSPORT' => 'Hotel transfers',
    _ => quantity > 1 ? '× $quantity' : '',
  };
}

/// A voucher the passenger can show at the airport, drawn as a ticket with
/// the code on the stub. The code is selectable and can be copied.
class VoucherCard extends StatelessWidget {
  const VoucherCard({super.key, required this.voucher});
  final Voucher voucher;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final v = voucher;
    final value = entitlementValue(
        type: v.type,
        quantity: v.quantity,
        amount: v.amount,
        currency: v.currency,
        points: v.points);
    final small = t.bodySmall?.copyWith(color: K.textSecondary);
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(entitlementName(v.type), style: t.titleMedium),
      if (value.isNotEmpty) ...[
        const SizedBox(height: K.s1),
        Text(value, style: K.dataLg(context)),
      ],
      if (v.basis.isNotEmpty) ...[
        const SizedBox(height: K.s2),
        Text(v.basis, style: small),
      ],
      if (v.validUntil != null) ...[
        const SizedBox(height: K.s1),
        Text('Valid until ${dayLabel(v.validUntil)} ${hhmm(v.validUntil)}', style: small),
      ],
    ]);
    final code = Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: SelectableText(v.code, style: K.dataMd(context).copyWith(letterSpacing: 1.2)),
      ),
      IconButton(
        tooltip: 'Copy voucher code',
        constraints: const BoxConstraints(minWidth: K.touch, minHeight: K.touch),
        icon: const Icon(Icons.copy, size: 18, color: K.textSecondary),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: v.code));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied ${v.code}')));
        },
      ),
    ]);
    return KCard(
      padding: const EdgeInsets.all(K.s4),
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 520) {
          return IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(alignment: Alignment.topCenter, child: IconChip(entitlementIcon(v.type))),
              const SizedBox(width: K.s4),
              Expanded(child: details),
              const SizedBox(width: K.s4),
              const _VerticalDashes(),
              const SizedBox(width: K.s4),
              SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    StatusPill(v.status),
                    const SizedBox(height: K.s2),
                    Text('VOUCHER CODE', style: K.label(context)),
                    code,
                  ],
                ),
              ),
            ]),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconChip(entitlementIcon(v.type), size: 40),
            const SizedBox(width: K.s3),
            Expanded(child: details),
            StatusPill(v.status),
          ]),
          const SizedBox(height: K.s3),
          const TicketDivider(inset: K.s4),
          const SizedBox(height: K.s2),
          Row(children: [
            Text('CODE', style: K.label(context)),
            const SizedBox(width: K.s3),
            Expanded(child: Align(alignment: Alignment.centerRight, child: code)),
          ]),
        ]);
      }),
    );
  }
}

class _VerticalDashes extends StatelessWidget {
  const _VerticalDashes();

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 2, child: CustomPaint(painter: _VerticalDashPainter()));
}

class _VerticalDashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = K.hairline
      ..strokeWidth = 1.5;
    for (var y = 0.0; y < size.height; y += 9) {
      canvas.drawLine(Offset(1, y), Offset(1, math.min(y + 5, size.height)), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A rule result with its reason (what applies, and why).
class EntitlementTile extends StatelessWidget {
  const EntitlementTile({super.key, required this.entitlement, this.compact = false});
  final Entitlement entitlement;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = entitlement;
    final value = entitlementValue(
        type: e.type,
        quantity: e.quantity,
        amount: e.amount,
        currency: e.currency,
        points: e.points);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: K.s2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconChip(entitlementIcon(e.type), size: 36),
        const SizedBox(width: K.s3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(e.label.isNotEmpty ? e.label : entitlementName(e.type),
                    style: t.titleMedium?.copyWith(fontSize: 15)),
              ),
              if (value.isNotEmpty) ...[
                const SizedBox(width: K.s2),
                Text(value, style: K.dataMd(context).copyWith(fontWeight: FontWeight.w600)),
              ],
            ]),
            if (!compact && e.explanation.isNotEmpty) ...[
              const SizedBox(height: K.s1),
              Text(e.explanation, style: t.bodySmall?.copyWith(color: K.textSecondary)),
            ],
            if (!compact && e.basis.isNotEmpty) ...[
              const SizedBox(height: K.s1),
              Text(e.basis, style: K.label(context)),
            ],
          ]),
        ),
      ]),
    );
  }
}

class EntitlementsCard extends StatelessWidget {
  const EntitlementsCard({super.key, required this.decision, this.compact = false, this.title = 'Your entitlements'});
  final EntitlementDecision decision;

  /// Labels and amounts only (the dashboard); the Vouchers page shows why.
  final bool compact;
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final items = decision.entitlements;
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: t.titleMedium))),
          if (decision.regulation != null) _Tag(decision.regulation!),
        ]),
        const SizedBox(height: K.s2),
        if (items.isEmpty)
          Text('Nothing applies to this booking yet.',
              style: t.bodyMedium?.copyWith(color: K.textSecondary)),
        for (final e in items) EntitlementTile(entitlement: e, compact: compact),
        if (!compact && decision.notes.isNotEmpty) ...[
          const Divider(height: K.s5),
          const SectionLabel('Does not apply'),
          const SizedBox(height: K.s2),
          for (final n in decision.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: K.s2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.remove_circle_outline, size: 16, color: K.textSecondary),
                ),
                const SizedBox(width: K.s2),
                Expanded(child: Text(n, style: t.bodySmall?.copyWith(color: K.textSecondary))),
              ]),
            ),
        ],
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: K.tealSoft, borderRadius: BorderRadius.circular(999)),
        child: Text(text, style: K.label(context).copyWith(color: K.teal)),
      );
}

// ---------------------------------------------------------------------------
// Recovery progress (dashboard)
// ---------------------------------------------------------------------------

enum _StepState { done, current, pending, alert }

class _Step {
  const _Step(this.title, this.detail, this.state);
  final String title, detail;
  final _StepState state;
}

/// Where the passenger is in their recovery: cancelled, rebooked, vouchers,
/// travel, plus an open case with staff when there is one. Built only from
/// what the REST tier returned.
class RecoveryTracker extends StatelessWidget {
  const RecoveryTracker({super.key, required this.booking, this.vouchers, this.cases});
  final Booking booking;

  /// Null while loading.
  final List<Voucher>? vouchers;
  final List<HandoffCase>? cases;

  List<_Step> _steps() {
    final f = booking.original;
    final c = booking.current;
    final reason = reasonText[f.disruptionReason];
    final rebooked = booking.isRebooked && c != null;
    final steps = <_Step>[];
    if (booking.isDisrupted || booking.isRebooked) {
      steps.add(_Step('Flight cancelled',
          '${f.number} · ${reason == null ? dayLabel(f.departureLocal) : 'because of $reason'}', _StepState.done));
    } else {
      steps.add(_Step('Booking ${titleCase(booking.status)}',
          '${f.number} · ${dayLabel(f.departureLocal)}', _StepState.done));
    }
    final open = (cases ?? const <HandoffCase>[]).where((x) => x.isOpen).toList();
    if (open.isNotEmpty) {
      steps.add(_Step('With our team', 'Case #${open.first.id}. A person will contact you.', _StepState.alert));
    }
    if (rebooked) {
      steps.add(_Step('Rebooked', '${c.number} · ${dayLabel(c.departureLocal)}, seat ${booking.seat ?? '-'}',
          _StepState.done));
      final live = vouchers?.where((v) => v.isLive).length;
      steps.add(_Step(
        'Vouchers',
        live == null
            ? 'Checking…'
            : live == 0
                ? 'None apply to this journey.'
                : '$live issued to you.',
        _StepState.done,
      ));
      steps.add(_Step('Travel',
          'Departs ${city(f.origin)} ${dayLabel(c.departureLocal)} at ${hhmm(c.departureLocal)}.',
          _StepState.current));
    } else if (booking.isDisrupted) {
      steps.add(const _Step('Choose a new flight', 'Same route and cabin, at no charge.', _StepState.current));
      steps.add(const _Step('Collect your vouchers', 'Issued as soon as you rebook.', _StepState.pending));
      steps.add(const _Step('Travel', 'Your new departure will show here.', _StepState.pending));
    } else {
      steps.add(_Step('Travel', 'Departs ${dayLabel(f.departureLocal)} at ${hhmm(f.departureLocal)}.',
          _StepState.current));
    }
    return steps;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final steps = _steps();
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text('Your recovery', style: t.titleMedium)),
        const SizedBox(height: K.s4),
        for (final (i, s) in steps.indexed) _StepRow(step: s, last: i == steps.length - 1),
      ]),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.last});
  final _Step step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final (bg, gradient, titleColor, detailColor, dot, word) = switch (step.state) {
      _StepState.done => (K.elevated, null, K.textPrimary, K.textSecondary, K.teal, 'done'),
      _StepState.current => (null, K.primaryGradient, Colors.white, Colors.white, K.glow, 'now'),
      _StepState.alert => (K.amber, null, K.base, K.base, K.amber, 'in progress'),
      _StepState.pending => (K.inset, null, K.textSecondary, K.textSecondary, K.hairline, 'to do'),
    };
    return Semantics(
      label: '${step.title}, $word. ${step.detail}',
      excludeSemantics: true,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 18,
            child: Column(children: [
              const SizedBox(height: 14),
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: step.state == _StepState.pending ? K.surface : dot,
                  border: Border.all(color: dot, width: 2),
                ),
                child: step.state == _StepState.done
                    ? const Icon(Icons.check, size: 9, color: K.base)
                    : null,
              ),
              if (!last) Expanded(child: Container(width: 2, color: K.hairline)),
            ]),
          ),
          const SizedBox(width: K.s3),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : K.s3),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: K.s3),
                decoration: BoxDecoration(
                  color: bg,
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(14),
                  border: step.state == _StepState.pending ? Border.all(color: K.hairline) : null,
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(step.title, style: t.titleMedium?.copyWith(fontSize: 15, color: titleColor)),
                  const SizedBox(height: 2),
                  Text(step.detail, style: t.bodySmall?.copyWith(color: detailColor)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Policy citations (M08) and hand-off (M15)
// ---------------------------------------------------------------------------

String sourceName(String source) => switch (source) {
      'kq-conditions-of-carriage' => 'KQ Conditions of Carriage',
      'eu261' => 'EU Regulation 261/2004',
      'montreal-convention' => 'Montreal Convention',
      _ => source,
    };

/// The clauses an answer was grounded in, with their similarity scores.
class CitationList extends StatelessWidget {
  const CitationList({super.key, required this.hits});
  final List<Map<String, dynamic>> hits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(K.s4),
      decoration: BoxDecoration(
        color: K.inset,
        borderRadius: BorderRadius.circular(K.radius),
        border: Border.all(color: K.hairline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.menu_book_outlined, size: 16, color: K.glow),
          const SizedBox(width: K.s2),
          Text('Sources', style: t.labelMedium),
        ]),
        const SizedBox(height: K.s3),
        for (final h in hits)
          Padding(
            padding: const EdgeInsets.only(bottom: K.s2),
            child: Row(children: [
              const Icon(Icons.description_outlined, size: 16, color: K.textSecondary),
              const SizedBox(width: K.s2),
              Expanded(
                child: Text(
                  '${sourceName(h['source'] as String? ?? '')} · ${h['clause_ref'] ?? ''}',
                  style: t.bodySmall,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: K.elevated, borderRadius: BorderRadius.circular(999)),
                child: Text(((h['similarity'] as num?) ?? 0).toStringAsFixed(2), style: K.label(context)),
              ),
            ]),
          ),
      ]),
    );
  }
}

class HandoffCard extends StatelessWidget {
  const HandoffCard({super.key, required this.handoff});
  final HandoffCase handoff;

  static String triggerText(String trigger) => switch (trigger) {
        'LOW_SIMILARITY' => 'Your question needs a person to answer it.',
        'NO_ALTERNATIVES' => 'There are no seats on other flights in your cabin.',
        'STEP_LIMIT' => 'Your request needs a person to finish it.',
        'REBOOKING_FAILED' => 'The rebooking could not be completed.',
        'PASSENGER_REQUEST' => 'You asked to speak to a person.',
        'FRUSTRATION' => 'This wasn\'t working for you, so a person is taking over.',
        _ => 'A member of staff will follow up.',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final open = handoff.isOpen;
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconChip(Icons.support_agent,
              color: open ? K.amber : K.teal, background: open ? K.amberSoft : K.tealSoft, size: 40),
          const SizedBox(width: K.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Case #${handoff.id}', style: t.titleMedium),
              if (handoff.createdAt != null)
                Text('Opened ${since(handoff.createdAt)}',
                    style: t.bodySmall?.copyWith(color: K.textSecondary)),
            ]),
          ),
          StatusPill(handoff.status),
        ]),
        const SizedBox(height: K.s3),
        Text(triggerText(handoff.trigger), style: t.bodyMedium),
        const SizedBox(height: K.s1),
        Text(
          open
              ? 'A Kenya Airways agent can see your booking and your last question, '
                  'and will contact you on the details in your booking.'
              : 'Resolved by our team${handoff.resolvedAt == null ? '' : ' ${since(handoff.resolvedAt)}'}.',
          style: t.bodySmall?.copyWith(color: K.textSecondary),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat (M05, M08)
// ---------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.text, required this.fromUser, this.writing = false});
  final String text;
  final bool fromUser;

  /// The reply is still arriving: a cursor follows the words.
  final bool writing;

  /// The model sometimes marks words as **bold** in Markdown; the bubble is
  /// plain text, so the markers are dropped rather than shown.
  static String plain(String text) => text.replaceAll(RegExp(r'\*\*|__'), '');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final text = fromUser ? this.text : plain(this.text);
    // Bubbles take at most 80% of the conversation column (not of the
    // browser window), so lines stay readable on a wide screen.
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: K.s3),
      decoration: BoxDecoration(
        color: fromUser ? K.crimson600 : K.elevated,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(fromUser ? 18 : 4),
          bottomRight: Radius.circular(fromUser ? 4 : 18),
        ),
        border: fromUser ? null : Border.all(color: K.hairline),
      ),
      child: writing
          ? Text.rich(TextSpan(children: [
              TextSpan(text: text),
              const WidgetSpan(alignment: PlaceholderAlignment.middle, child: TypingCursor()),
            ]), style: t.bodyMedium?.copyWith(color: Colors.white))
          : SelectableText(text, style: t.bodyMedium?.copyWith(color: Colors.white)),
    );
    return Semantics(
      label: fromUser ? 'You said' : 'Kestrel said',
      child: LayoutBuilder(
        builder: (context, c) => Row(
          mainAxisAlignment: fromUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!fromUser) ...[const KestrelMark(size: 28), const SizedBox(width: K.s2)],
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: c.maxWidth * .8),
                child: bubble,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The blinking bar at the end of a reply that is still being written.
/// Steady (no blink) with reduce-motion.
class TypingCursor extends StatefulWidget {
  const TypingCursor({super.key});

  @override
  State<TypingCursor> createState() => _TypingCursorState();
}

class _TypingCursorState extends State<TypingCursor> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: FadeTransition(
          opacity: _c,
          child: Container(
            width: 2,
            height: 16,
            margin: const EdgeInsets.only(left: 2),
            color: K.glow,
          ),
        ),
      );
}

/// Three pulsing dots while the agent works, with what it is doing
/// ("Checking flights…") when a streamed reply says so.
class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key, this.label});

  /// What the assistant is doing; null shows the dots alone.
  final String? label;

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect "reduce motion": show static dots.
    final still = MediaQuery.of(context).disableAnimations;
    final label = widget.label;
    return Semantics(
      label: label ?? 'Kestrel is working on it',
      liveRegion: true,
      excludeSemantics: true,
      child: Row(children: [
        const KestrelMark(size: 28),
        const SizedBox(width: K.s2),
        Flexible(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: 14),
          decoration: BoxDecoration(
            color: K.elevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: K.hairline),
          ),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...List.generate(3, (i) {
                final phase = ((_c.value * 3) - i).clamp(0.0, 1.0);
                final a = still ? 1.0 : (phase < .5 ? .35 + phase * 1.3 : 1.65 - phase * 1.3);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Opacity(
                    opacity: a.clamp(.35, 1.0),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration:
                          const BoxDecoration(color: K.textSecondary, shape: BoxShape.circle),
                    ),
                  ),
                );
                }),
                if (label != null) ...[
                  const SizedBox(width: K.s2),
                  Flexible(
                    child: Text(label,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: K.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        )),
      ]),
    );
  }
}
