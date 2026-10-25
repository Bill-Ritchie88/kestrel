import 'package:flutter/material.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../state/recommend.dart';
import '../widgets/next_steps.dart';
import '../widgets/shell.dart';
import '../widgets/skeleton.dart';
import 'confirm_screen.dart';

/// My trip: the passenger's dashboard. The trip as a ticket, the flights they
/// can move to (or, once rebooked, their vouchers), where they are in the
/// recovery, what they're entitled to, and a way into the assistant.
///
/// Everything comes from the TripStore (GET /api/trip, loaded once after
/// sign-in): skeletons until the first load arrives, then the stored trip at
/// once on every visit, refreshed quietly behind it.
class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.onAsk});
  final void Function(String text, {String? intent}) onAsk;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  /// Back from confirming, the booking has either changed (rebooked) or the
  /// flight sold out; either way the trip needs a fresh look.
  Future<void> _choose(Flight f) async {
    final store = TripScope.read(context);
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConfirmScreen(flight: f)),
    );
    store.refreshQuietly();
  }

  Future<void> _refresh() async {
    try {
      await TripScope.read(context).refresh();
    } catch (e) {
      if (mounted) handleApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = TripScope.of(context);
    final trip = store.trip;
    final shell = ShellScope.of(context);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(builder: (context, c) {
        final twoPane = c.maxWidth >= Breakpoints.twoPane;
        final padding = pagePadding(c.maxWidth,
            maxWidth: Breakpoints.dashboard, top: twoPane ? 28 : K.s4, bottom: K.s6);
        if (trip == null) {
          return ListView(padding: padding, children: [
            if (store.failure != null && !store.loading)
              ErrorNotice(message: failureMessage(store.failure!), onRetry: _refresh)
            else
              const TripSkeleton(),
          ]);
        }
        final booking = trip.booking;
        final vouchers = trip.vouchers;
        final rec = recommend(trip);
        final main = <Widget>[
          _Greeting(booking: booking, showTier: !twoPane),
          const SizedBox(height: K.s5),
          if (rec != null) ...[
            RecommendCard(
              recommendation: rec,
              busy: shell.requestingPerson,
              onAction: () => switch (rec.action) {
                RecommendedAction.review => _choose(rec.flight!),
                RecommendedAction.vouchers => shell.go(Section.vouchers),
                RecommendedAction.person => askForPerson(context,
                    summary: 'No suitable alternative flight; passenger asked for a person.'),
              },
            ),
            const SizedBox(height: K.s5),
          ],
          TripTicket(booking: booking),
          const SizedBox(height: K.s6),
          ..._nextStep(trip, shell),
        ];
        final side = <Widget>[
          RecoveryTracker(booking: booking, vouchers: vouchers, cases: trip.cases),
          const SizedBox(height: K.s4),
          EntitlementsCard(decision: trip.decision, compact: true, title: 'What you\'re entitled to'),
          Align(
            alignment: Alignment.centerRight,
            child: LinkButton(label: 'Vouchers & entitlements', onPressed: () => shell.go(Section.vouchers)),
          ),
          const SizedBox(height: K.s3),
          _AskCard(suggestions: trip.suggestions, onAsk: widget.onAsk),
        ];
        return ListView(
          padding: padding,
          children: twoPane
              ? [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: main)),
                    const SizedBox(width: K.s5),
                    SizedBox(
                      width: 360,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: side),
                    ),
                  ]),
                ]
              : [...main, const SizedBox(height: K.s5), ...side],
        );
      }),
    );
  }

  /// Disrupted: the flights to move to. Rebooked: the vouchers to collect.
  List<Widget> _nextStep(Trip trip, ShellController shell) {
    final t = Theme.of(context).textTheme;
    final booking = trip.booking;
    final flights = trip.alternatives;
    if (booking.isDisrupted) {
      final f = booking.original;
      return [
        SectionHeader('Flights from ${city(f.origin)}',
            action: 'View all', onAction: () => shell.go(Section.flights)),
        Text('Same route and cabin, earliest arrival first. Times are local to each airport.',
            style: t.bodySmall?.copyWith(color: K.textSecondary)),
        const SizedBox(height: K.s4),
        if (flights.isEmpty)
          KCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('No seats on other flights', style: t.titleMedium),
              const SizedBox(height: K.s2),
              Text(
                'There are no free seats in your cabin on this route right now. '
                'A Kenya Airways agent can look at other options with you.',
                style: t.bodyMedium?.copyWith(color: K.textSecondary),
              ),
              const SizedBox(height: K.s4),
              PrimaryButton(
                label: 'Talk to a person',
                busy: shell.requestingPerson,
                onPressed: () => askForPerson(context,
                    summary: 'No suitable alternative flight; passenger asked for a person.'),
              ),
            ]),
          ),
        for (final (i, flight) in flights.take(3).indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: K.s3),
            child: FlightOptionCard(flight: flight, recommended: i == 0, onSelect: () => _choose(flight)),
          ),
      ];
    }
    if (booking.isRebooked) {
      final live = trip.vouchers.where((v) => v.isLive).toList();
      return [
        SectionHeader('Your vouchers', action: 'View all', onAction: () => shell.go(Section.vouchers)),
        const SizedBox(height: K.s2),
        if (live.isEmpty)
          Text('No vouchers apply to this journey.', style: t.bodyMedium?.copyWith(color: K.textSecondary)),
        for (final v in live.take(3))
          Padding(padding: const EdgeInsets.only(bottom: K.s3), child: VoucherCard(voucher: v)),
      ];
    }
    return const [];
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.booking, required this.showTier});
  final Booking booking;
  final bool showTier;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = booking.firstName.isNotEmpty ? booking.firstName : booking.lastName;
    final line = booking.isRebooked
        ? 'You\'re rebooked. Here\'s your new trip and what you\'re entitled to.'
        : booking.isDisrupted
            ? 'Your flight was cancelled. Here\'s everything you need to get moving.'
            : 'Here\'s your trip.';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text('Hi, $name', style: t.headlineSmall?.copyWith(fontSize: 28))),
          const SizedBox(height: K.s1),
          Text(line, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
        ]),
      ),
      if (showTier)
        Container(
          margin: const EdgeInsets.only(left: K.s3, top: K.s1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: K.amberSoft, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.workspace_premium, size: 15, color: K.amber),
            const SizedBox(width: 4),
            Text(titleCase(booking.tier), style: K.label(context).copyWith(color: K.amber)),
          ]),
        ),
    ]);
  }
}

/// A way into the assistant from the dashboard, with the questions
/// passengers ask most.
class _AskCard extends StatelessWidget {
  const _AskCard({required this.suggestions, required this.onAsk});

  /// The server's next steps for this booking (GET /api/trip).
  final List<Suggestion> suggestions;
  final void Function(String text, {String? intent}) onAsk;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final prompts = suggestions.isNotEmpty
        ? suggestions
        : [Suggestion({'label': 'What am I entitled to?', 'intent': 'entitlements'})];
    return KCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const KestrelMark(size: 30),
          const SizedBox(width: K.s3),
          Expanded(child: Semantics(header: true, child: Text('Ask Kestrel', style: t.titleMedium))),
        ]),
        const SizedBox(height: K.s2),
        Text('Answers come from your booking and the conditions of carriage.',
            style: t.bodySmall?.copyWith(color: K.textSecondary)),
        const SizedBox(height: K.s3),
        for (final p in prompts)
          Padding(
            padding: const EdgeInsets.only(top: K.s2),
            child: Material(
              color: K.inset,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => runSuggestion(context, p, ask: onAsk),
                child: SizedBox(
                  height: K.touch,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: K.s3),
                    child: Row(children: [
                      Icon(suggestionIcon(p) ?? Icons.chat_bubble_outline_rounded, size: 18, color: K.glow),
                      const SizedBox(width: K.s3),
                      Expanded(child: Text(p.label, style: t.bodyMedium)),
                      const Icon(Icons.chevron_right, color: K.textSecondary),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
