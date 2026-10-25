import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/shell.dart';
import '../widgets/system_state.dart';

/// M11 · Confirm rebooking (UC4, FR-03). The seat is claimed by the atomic
/// stored procedure (row lock, SKIP LOCKED); if the last seat goes to someone
/// else first the server answers 409 and the passenger picks again.
///
/// Pops with `true` when the list of flights should be refreshed.
class ConfirmScreen extends StatefulWidget {
  const ConfirmScreen({super.key, required this.flight});
  final Flight flight;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  bool _busy = false;
  String? _error;
  bool _soldOut = false;

  Future<void> _confirm() async {
    final session = SessionScope.read(context);
    final trip = TripScope.maybeRead(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await session.api.rebook(widget.flight.id);
      // The confirmation shows the booking the rebooking returned; the trip
      // everywhere else catches up behind it.
      trip?.refreshQuietly();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ConfirmedScreen(result: result)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() {
        _soldOut = e.status == 409;
        _error = msg;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final booking = SessionScope.of(context).booking;
    final f = widget.flight;
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm your new flight')),
      body: PageList(
        children: [
          Text('Check the details, then confirm. There is no charge for this change.',
              style: t.bodyMedium?.copyWith(color: K.textSecondary)),
          const SizedBox(height: K.s5),
          if (booking != null) ...[
            const SectionLabel('Cancelled'),
            const SizedBox(height: K.s2),
            Opacity(
              opacity: .7,
              child: KCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${booking.original.number} · ${dayLabel(booking.original.departureLocal)}',
                      style: t.titleMedium?.copyWith(decoration: TextDecoration.lineThrough)),
                  const SizedBox(height: K.s4),
                  RouteLine(
                    origin: booking.original.origin,
                    destination: booking.original.destination,
                    departureLocal: booking.original.departureLocal,
                    arrivalLocal: booking.original.arrivalLocal,
                    cancelled: true,
                  ),
                ]),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: K.s3),
              child: Center(child: IconChip(Icons.arrow_downward, size: 40)),
            ),
          ],
          const SectionLabel('Your new flight'),
          const SizedBox(height: K.s2),
          FlightOptionCard(flight: f, recommended: false),
          const SizedBox(height: K.s4),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.event_seat, size: 18, color: K.textSecondary),
            const SizedBox(width: K.s2),
            Expanded(
              child: Text(
                'We\'ll hold ${_withArticle(titleCase(f.cabin ?? booking?.cabin ?? 'economy'))} seat for you '
                'and issue any vouchers you\'re entitled to straight away.',
                style: t.bodySmall?.copyWith(color: K.textSecondary),
              ),
            ),
          ]),
          // 409: the last seat went to someone else first. Nothing changed on
          // the booking; the way forward is another flight.
          if (_soldOut) ...[
            const SizedBox(height: K.s5),
            SystemStateCard.seatTaken(
              onChooseAnother: () => Navigator.of(context).pop(true),
              onPerson: () => askForPerson(context,
                  summary: 'Rebooking refused: the last seat on ${f.number} went to another passenger first.'),
            ),
          ] else ...[
            if (_error != null) ...[
              const SizedBox(height: K.s4),
              ErrorNotice(message: _error!, onRetry: _confirm),
            ],
            const SizedBox(height: K.s5),
            PrimaryButton(label: 'Confirm rebooking', busy: _busy, onPressed: _confirm),
            const SizedBox(height: K.s3),
            SecondaryButton(
              label: 'Back',
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            ),
          ],
        ],
      ),
    );
  }
}

/// M12 · Rebooking confirmed, with the vouchers issued in the same request.
class ConfirmedScreen extends StatelessWidget {
  const ConfirmedScreen({super.key, required this.result});
  final Map<String, dynamic> result;

  void _goTo(BuildContext context, Section s) {
    ShellScope.read(context).go(s);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final bookingJson = asMap(result['booking']);
    final booking = bookingJson.isEmpty ? SessionScope.of(context).booking : Booking(bookingJson);
    final vouchers = asList(asMap(result['entitlements'])['vouchers'])
        .map(Voucher.new)
        .where((v) => v.isLive)
        .toList();
    return Scaffold(
      // "Done" stays in reach however many vouchers were issued below.
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Rebooked'),
        actions: [
          TextButton(
            onPressed: () => _goTo(context, Section.trip),
            style: TextButton.styleFrom(
                foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
            child: const Text('Done'),
          ),
          const SizedBox(width: K.s2),
        ],
      ),
      body: PageList(
        children: [
          Semantics(
            liveRegion: true,
            child: Column(children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(color: K.tealSoft, shape: BoxShape.circle),
                child: const Icon(Icons.check_circle, color: K.teal, size: 56),
              ),
              const SizedBox(height: K.s4),
              Text('You\'re rebooked', style: t.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: K.s1),
              Text(
                'Seat ${result['assigned_seat'] ?? booking?.seat ?? ''}'
                '${booking == null ? '' : ' · ${titleCase(booking.cabin)}'}',
                style: K.dataMd(context),
                textAlign: TextAlign.center,
              ),
            ]),
          ),
          const SizedBox(height: K.s5),
          if (booking != null) TripTicket(booking: booking),
          if (vouchers.isNotEmpty) ...[
            const SizedBox(height: K.s5),
            const SectionHeader('Issued to you'),
            const SizedBox(height: K.s2),
            for (final v in vouchers)
              Padding(
                padding: const EdgeInsets.only(bottom: K.s3),
                child: VoucherCard(voucher: v),
              ),
          ],
          const SizedBox(height: K.s4),
          PrimaryButton(label: 'Back to my trip', onPressed: () => _goTo(context, Section.trip)),
          const SizedBox(height: K.s3),
          SecondaryButton(
            label: 'All vouchers & entitlements',
            icon: Icons.confirmation_number_outlined,
            onPressed: () => _goTo(context, Section.vouchers),
          ),
        ],
      ),
    );
  }
}

/// "an Economy", "a Business".
String _withArticle(String word) => '${word.startsWith(RegExp('[AEIOU]')) ? 'an' : 'a'} $word';
