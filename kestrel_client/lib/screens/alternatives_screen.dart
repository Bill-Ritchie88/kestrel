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
import '../widgets/shell.dart';
import '../widgets/skeleton.dart';
import 'confirm_screen.dart';

/// M09 · Flights (UC4, FR-03). Same route and cabin, earliest arrival first,
/// as rows like a flight search: the top five from the TripStore, shown at
/// once and refreshed behind the page.
class AlternativesScreen extends StatelessWidget {
  const AlternativesScreen({super.key});

  Future<void> _refresh(BuildContext context) async {
    try {
      await TripScope.read(context).refresh();
    } catch (e) {
      if (context.mounted) handleApiError(context, e);
    }
  }

  Future<void> _choose(BuildContext context, Flight f) async {
    final store = TripScope.read(context);
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConfirmScreen(flight: f)),
    );
    // Rebooked, or the flight sold out while the passenger was deciding:
    // either way, fetch fresh seats.
    store.refreshQuietly();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final store = TripScope.of(context);
    final trip = store.trip;
    final booking = trip?.booking;
    final shell = ShellScope.of(context);
    final f = booking?.original;
    final current = booking?.current;
    final flights = trip?.alternatives;
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: PageList(
        maxWidth: Breakpoints.grid - 140,
        children: [
          const SizedBox(height: K.s3),
          PageHeading(
            'Other flights',
            subtitle: f == null
                ? null
                : '${city(f.origin)} to ${city(f.destination)} · same cabin '
                    '(${titleCase(booking!.cabin)}), earliest arrival first. '
                    'All times are local to each airport.',
          ),
          const SizedBox(height: K.s5),
          if (booking != null && booking.isRebooked && current != null) ...[
            InfoBanner(
              text: 'You\'re booked on ${current.number} (${dayLabel(current.departureLocal)}, '
                  '${hhmm(current.departureLocal)}). Choosing a flight here moves your booking again.',
              icon: Icons.check_circle_outline,
            ),
            const SizedBox(height: K.s4),
          ],
          if (trip == null)
            store.failure != null && !store.loading
                ? ErrorNotice(message: failureMessage(store.failure!), onRetry: () => _refresh(context))
                : const ListSkeleton(label: 'Loading flights', item: FlightRowSkeleton()),
          if (flights != null && flights.isEmpty) ...[
            KCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No seats on other flights', style: t.titleMedium),
                const SizedBox(height: K.s2),
                Text(
                  'There are no free seats in your cabin on this route right now. '
                  'A Kenya Airways agent can look at other options with you.',
                  style: t.bodyMedium?.copyWith(color: K.textSecondary),
                ),
              ]),
            ),
            const SizedBox(height: K.s4),
            PrimaryButton(
              label: 'Talk to a person',
              busy: shell.requestingPerson,
              onPressed: () => askForPerson(context,
                  summary: 'No suitable alternative flight; passenger asked for a person.'),
            ),
          ],
          if (flights != null)
            for (final (i, flight) in flights.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: K.s3),
                child: FlightOptionCard(
                    flight: flight, recommended: i == 0, onSelect: () => _choose(context, flight)),
              ),
        ],
      ),
    );
  }
}
