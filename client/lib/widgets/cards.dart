import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../format.dart';
import '../theme.dart';
import 'common.dart';

// ---------------------------------------------------------------------------
// Booking and flights (M05, M09, M11, M12)
// ---------------------------------------------------------------------------

/// The passenger's disruption at a glance: cancelled flight, reason, and the
/// recovery flight once rebooked.
class BookingCard extends StatelessWidget {
  const BookingCard({super.key, required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final f = booking.original;
    final current = booking.current;
    final reason = reasonText[f.disruptionReason];
    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('${f.number} · ${dayLabel(f.departureLocal)}',
                  style: t.titleMedium),
            ),
            StatusPill(booking.isRebooked ? 'REACCOMMODATED' : (f.status ?? booking.status)),
          ]),
          const SizedBox(height: K.s3),
          FlightLeg(
            origin: f.origin,
            destination: f.destination,
            departureLocal: f.departureLocal,
            arrivalLocal: f.arrivalLocal,
          ),
          if (reason != null && !booking.isRebooked) ...[
            const SizedBox(height: K.s3),
            Text('Cancelled because of $reason.',
                style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ],
          if (current != null && booking.isRebooked) ...[
            const Divider(height: K.s5, color: K.hairline),
            Row(children: [
              const Icon(Icons.check_circle, size: 18, color: K.teal),
              const SizedBox(width: K.s2),
              Expanded(
                child: Text(
                  'Now on ${current.number} · ${dayLabel(current.departureLocal)}',
                  style: t.titleMedium,
                ),
              ),
            ]),
            const SizedBox(height: K.s3),
            FlightLeg(
              origin: f.origin,
              destination: f.destination,
              departureLocal: current.departureLocal,
              arrivalLocal: current.arrivalLocal,
            ),
            const SizedBox(height: K.s3),
            Text(
              'Seat ${booking.seat ?? '-'} · ${titleCase(booking.cabin)}',
              style: K.dataMd(context),
            ),
          ],
        ],
      ),
    );
  }
}

/// One recovery flight (M09). The whole card is the touch target.
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
    return KCard(
      highlighted: recommended,
      onTap: onSelect,
      semanticLabel: '${recommended ? 'Earliest arrival. ' : ''}'
          'Flight ${flight.number}, ${dayLabel(flight.departureLocal)}, '
          'departs ${hhmm(flight.departureLocal)}, arrives ${hhmm(flight.arrivalLocal)}, '
          '$seats ${seats == 1 ? 'seat' : 'seats'} left in ${titleCase(flight.cabin ?? '')}. '
          'Double tap to choose.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('${flight.number} · ${dayLabel(flight.departureLocal)}',
                    style: t.titleMedium),
              ),
              if (recommended)
                Text('EARLIEST ARRIVAL', style: K.label(context).copyWith(color: K.glow)),
            ]),
            const SizedBox(height: K.s3),
            FlightLeg(
              origin: flight.origin,
              destination: flight.destination,
              departureLocal: flight.departureLocal,
              arrivalLocal: flight.arrivalLocal,
            ),
            const SizedBox(height: K.s3),
            Row(children: [
              Icon(Icons.event_seat,
                  size: 16, color: seats <= 3 ? K.amber : K.textSecondary),
              const SizedBox(width: K.s1),
              Text(
                '$seats ${seats == 1 ? 'seat' : 'seats'} left · ${titleCase(flight.cabin ?? '')}',
                style: t.bodySmall?.copyWith(color: seats <= 3 ? K.amber : K.textSecondary),
              ),
              const Spacer(),
              if (onSelect != null) const Icon(Icons.chevron_right, color: K.textSecondary),
            ]),
          ],
        ),
      ),
    );
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

/// A voucher the passenger can show at the airport. The code is selectable
/// and can be copied.
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
    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(entitlementIcon(v.type), color: K.glow),
            const SizedBox(width: K.s3),
            Expanded(child: Text(entitlementName(v.type), style: t.titleMedium)),
            StatusPill(v.status),
          ]),
          if (value.isNotEmpty) ...[
            const SizedBox(height: K.s3),
            Text(value, style: K.dataLg(context)),
          ],
          const SizedBox(height: K.s3),
          Container(
            padding: const EdgeInsets.only(left: K.s3),
            decoration: const BoxDecoration(color: K.inset),
            child: Row(children: [
              Expanded(
                child: SelectableText(v.code,
                    style: K.dataMd(context).copyWith(letterSpacing: 1.2)),
              ),
              IconButton(
                tooltip: 'Copy voucher code',
                constraints: const BoxConstraints(minWidth: K.touch, minHeight: K.touch),
                icon: const Icon(Icons.copy, size: 18, color: K.textSecondary),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: v.code));
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Copied ${v.code}')));
                },
              ),
            ]),
          ),
          if (v.basis.isNotEmpty) ...[
            const SizedBox(height: K.s2),
            Text(v.basis, style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ],
          if (v.validUntil != null) ...[
            const SizedBox(height: K.s1),
            Text('Valid until ${dayLabel(v.validUntil)} ${hhmm(v.validUntil)}',
                style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// A rule result with its reason (what applies, and why).
class EntitlementTile extends StatelessWidget {
  const EntitlementTile({super.key, required this.entitlement});
  final Entitlement entitlement;

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
        Icon(entitlementIcon(e.type), size: 20, color: K.glow),
        const SizedBox(width: K.s3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(e.label.isNotEmpty ? e.label : entitlementName(e.type),
                    style: t.titleMedium),
              ),
              if (value.isNotEmpty) Text(value, style: K.dataMd(context)),
            ]),
            if (e.explanation.isNotEmpty) ...[
              const SizedBox(height: K.s1),
              Text(e.explanation, style: t.bodySmall?.copyWith(color: K.textSecondary)),
            ],
            if (e.basis.isNotEmpty) ...[
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
  const EntitlementsCard({super.key, required this.decision});
  final EntitlementDecision decision;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final items = decision.entitlements;
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionLabel('Your entitlements'),
        const SizedBox(height: K.s2),
        if (items.isEmpty)
          Text('Nothing applies to this booking yet.', style: t.bodyMedium),
        for (final e in items) EntitlementTile(entitlement: e),
        if (decision.notes.isNotEmpty) ...[
          const Divider(height: K.s5, color: K.hairline),
          const SectionLabel('Does not apply'),
          const SizedBox(height: K.s2),
          for (final n in decision.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: K.s2),
              child: Text(n, style: t.bodySmall?.copyWith(color: K.textSecondary)),
            ),
        ],
      ]),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionLabel('Sources'),
      const SizedBox(height: K.s2),
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
            Text(((h['similarity'] as num?) ?? 0).toStringAsFixed(2),
                style: K.label(context)),
          ]),
        ),
    ]);
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
        _ => 'A member of staff will follow up.',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.support_agent, color: K.amber),
          const SizedBox(width: K.s3),
          Expanded(child: Text('Case #${handoff.id}', style: t.titleMedium)),
          StatusPill(handoff.status),
        ]),
        const SizedBox(height: K.s3),
        Text(triggerText(handoff.trigger), style: t.bodyMedium),
        const SizedBox(height: K.s1),
        Text('A Kenya Airways agent has your booking and this conversation, '
            'and will contact you. You don\'t need to repeat anything.',
            style: t.bodySmall?.copyWith(color: K.textSecondary)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat (M05, M08)
// ---------------------------------------------------------------------------

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.text, required this.fromUser});
  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
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
      child: SelectableText(text, style: t.bodyMedium?.copyWith(color: Colors.white)),
    );
    return Semantics(
      label: fromUser ? 'You said' : 'Kestrel said',
      child: Row(
        mainAxisAlignment: fromUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!fromUser) ...[const KestrelMark(size: 28), const SizedBox(width: K.s2)],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

/// Three pulsing dots while the agent works.
class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key});

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
    return Semantics(
      label: 'Kestrel is working on it',
      liveRegion: true,
      child: Row(children: [
        const KestrelMark(size: 28),
        const SizedBox(width: K.s2),
        Container(
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
              children: List.generate(3, (i) {
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
            ),
          ),
        ),
      ]),
    );
  }
}
