import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/session.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import 'confirm_screen.dart';
import 'seat_map_screen.dart';

/// FR-17 · The assistant's rebooking proposal, drawn under its reply. The
/// assistant cannot rebook: only this tap sends the proposal's signed token
/// back to POST /api/reaccommodate, which checks it is for this booking, this
/// flight and this seat choice, unexpired and unused. "Choose a seat" goes the
/// seat map's own way, with the Confirm page there.
class RebookProposalCard extends StatefulWidget {
  const RebookProposalCard({super.key, required this.proposal});

  /// The `rebook_proposal` event: flight, seat_id, confirmation_token.
  final Map<String, dynamic> proposal;

  @override
  State<RebookProposalCard> createState() => _RebookProposalCardState();
}

class _RebookProposalCardState extends State<RebookProposalCard> {
  bool _busy = false;
  bool _done = false;
  String? _error;

  Flight get _flight => Flight(asMap(widget.proposal['flight']));

  Future<void> _confirm() async {
    final session = SessionScope.read(context);
    final trip = TripScope.maybeRead(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await session.api.rebook(
        _flight.id,
        seatId: widget.proposal['seat_id'] as String?,
        confirmationToken: widget.proposal['confirmation_token'] as String?,
      );
      trip?.refreshQuietly();
      if (!mounted) return;
      setState(() => _done = true);
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConfirmedScreen(result: result)));
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _chooseSeat() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeatMapScreen(flight: _flight)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return KCard(
      highlighted: !_done,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text('Confirm rebooking', style: t.titleMedium)),
        const SizedBox(height: K.s1),
        Text(
          _done
              ? 'Rebooked. Your trip has been updated.'
              : 'Nothing changes until you confirm. Kestrel will choose your seat, or you can pick one.',
          style: t.bodySmall?.copyWith(color: K.textSecondary),
        ),
        const SizedBox(height: K.s3),
        FlightOptionCard(flight: _flight),
        if (_error != null) ...[
          const SizedBox(height: K.s3),
          ErrorNotice(message: _error!),
        ],
        if (!_done) ...[
          const SizedBox(height: K.s4),
          PrimaryButton(label: 'Confirm rebooking', busy: _busy, onPressed: _busy ? null : _confirm),
          const SizedBox(height: K.s2),
          SecondaryButton(
            label: 'Choose a seat',
            icon: Icons.event_seat,
            height: 48,
            onPressed: _busy ? null : _chooseSeat,
          ),
        ],
      ]),
    );
  }
}
