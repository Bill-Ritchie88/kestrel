import '../api/models.dart';
import '../format.dart';

/// What the "Kestrel recommends" card and the assistant's first message lead
/// to.
enum RecommendedAction { review, vouchers, person }

/// "Kestrel recommends": written from the trip (GET /api/trip) alone, so it
/// is instant and states only what the server returned - the first flight
/// is the earliest arrival in the passenger's cabin (the REST tier's order),
/// and what the passenger is owed with it comes from the rules engine
/// (`includes`). No model call.
class Recommendation {
  const Recommendation({
    required this.text,
    required this.question,
    required this.action,
    required this.actionLabel,
    this.flight,
  });

  /// The card's words.
  final String text;

  /// Asked at the end of the assistant's first message ("Shall I book it?").
  final String question;
  final RecommendedAction action;
  final String actionLabel;

  /// The flight to review, for [RecommendedAction.review].
  final Flight? flight;
}

/// "today at 16:31", "tomorrow at 16:31", else "Sun 18 Oct at 16:31", from
/// the local time as the server wrote it.
String whenText(String? localIso, {DateTime? now}) {
  if (localIso == null || localIso.length < 16) return 'at an unknown time';
  final date = DateTime.tryParse(localIso.substring(0, 10));
  final today = now ?? DateTime.now();
  final days = date == null
      ? null
      : DateTime.utc(date.year, date.month, date.day)
          .difference(DateTime.utc(today.year, today.month, today.day))
          .inDays;
  final day = switch (days) { 0 => 'today', 1 => 'tomorrow', _ => dayLabel(localIso) };
  return '$day at ${hhmm(localIso)}';
}

String _list(List<String> items) => switch (items.length) {
      0 => '',
      1 => items.first,
      _ => '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}',
    };

/// The items the rules give, in a passenger's words.
List<String> owedItems(List<Map<String, dynamic>> items) {
  final out = <String>[];
  for (final e in items) {
    final qty = (e['quantity'] as num?)?.toInt() ?? 1;
    switch (e['entitlement_type']) {
      case 'MEAL':
        out.add(qty == 1 ? 'a meal voucher' : '$qty meal vouchers');
      case 'HOTEL':
        out.add(qty == 1 ? 'a hotel night' : '$qty hotel nights');
      case 'TRANSPORT':
        out.add('transfers');
      case 'ASANTE_POINTS':
        final points = (e['points'] as num?)?.toInt() ?? 0;
        out.add('${money(points.toDouble(), null)} Asante points');
      case 'CASH_COMPENSATION':
        out.add('${money((e['amount'] as num?)?.toDouble(), e['currency'] as String?)} compensation '
            '(after review)');
    }
  }
  return out;
}

Recommendation? recommend(Trip trip, {DateTime? now}) {
  final booking = trip.booking;
  if (booking.isDisrupted) {
    final flights = trip.alternatives;
    if (flights.isEmpty) {
      return const Recommendation(
        text: 'There are no free seats in your cabin on other flights right now. A Kenya Airways '
            'agent can look at other options with you.',
        question: 'Shall I pass your case to a person?',
        action: RecommendedAction.person,
        actionLabel: 'Talk to a person',
      );
    }
    final best = flights.first;
    final why = [
      if (best.badges.isEmpty || best.badges.contains('EARLIEST_ARRIVAL'))
        'the earliest arrival in ${city(best.destination)}',
      '${best.seatsLeft} ${best.seatsLeft == 1 ? 'seat' : 'seats'} left',
    ];
    // With this flight, from the rules; otherwise what applies now.
    final owed = owedItems(best.includes.isNotEmpty
        ? best.includes
        : trip.decision.entitlements
            .where((e) => e.status == 'ISSUED' || e.status == 'ELIGIBLE')
            .map((e) => e.json)
            .toList());
    return Recommendation(
      text: 'Your best option is ${best.number} ${whenText(best.departureLocal, now: now)} — '
          '${why.join(', ')}.'
          '${owed.isEmpty ? '' : ' You\'re owed ${_list(owed)}.'}',
      question: 'Shall I book it?',
      action: RecommendedAction.review,
      actionLabel: 'Review and confirm',
      flight: best,
    );
  }
  if (booking.isRebooked && booking.current != null) {
    final c = booking.current!;
    final live = trip.vouchers.where((v) => v.isLive).length;
    return Recommendation(
      text: 'You\'re booked on ${c.number} ${whenText(c.departureLocal, now: now)}, '
          'seat ${booking.seat ?? '-'}.'
          '${live == 0 ? '' : ' You have $live ${live == 1 ? 'voucher' : 'vouchers'} ready to use.'}',
      question: 'Anything else I can help with?',
      action: RecommendedAction.vouchers,
      actionLabel: 'Show my vouchers',
    );
  }
  return null;
}
