import 'package:flutter/material.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../state/trip.dart';
import '../theme.dart';
import 'api_error.dart';
import 'common.dart';

/// Migration 016 · Compensation and refunds. The amount and the rule always
/// come from the server's rules engine; the client shows them, sends the
/// claim, and shows where it stands. Staff approve, reject and pay it.

/// "2 h 30 min".
String hoursMinutes(int minutes) =>
    minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h${minutes % 60 == 0 ? '' : ' ${minutes % 60} min'}';

/// One claim and where it stands.
class ClaimCard extends StatelessWidget {
  const ClaimCard({super.key, required this.claim});
  final Claim claim;

  static String statusLine(Claim c) => switch (c.status) {
        'CLAIMED' => 'Waiting for review by Kenya Airways customer care.',
        'APPROVED' => 'Approved. The payment is being arranged.',
        'REJECTED' => 'Not approved: ${c.reason ?? 'no reason given'}.',
        'PAID' => 'Paid. Payment reference ${c.payoutReference ?? ''}.',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return KCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconChip(claim.isRefund ? Icons.undo : Icons.payments),
        const SizedBox(width: K.s4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(claim.isRefund ? 'Refund request' : 'Compensation claim', style: t.titleMedium),
              ),
              StatusPill(claim.status),
            ]),
            const SizedBox(height: K.s1),
            Text(claim.isRefund ? 'Your ticket price' : money(claim.amount, claim.currency),
                style: K.dataMd(context)),
            const SizedBox(height: K.s2),
            Text(statusLine(claim), style: t.bodyMedium),
            const SizedBox(height: K.s1),
            Text(claim.basis, style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ]),
        ),
      ]),
    );
  }
}

/// The Vouchers page's compensation section: the amount the rules give and
/// the rule, a "Claim compensation" button, then the claim's status. Nothing
/// when the rules give no compensation (no claim is possible then).
class CompensationPanel extends StatefulWidget {
  const CompensationPanel({super.key, required this.trip});
  final Trip trip;

  @override
  State<CompensationPanel> createState() => _CompensationPanelState();
}

class _CompensationPanelState extends State<CompensationPanel> {
  bool _busy = false;
  Claim? _made; // shown until the refreshed trip carries it

  Future<void> _claim() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final claim = await SessionScope.read(context).api.claimCompensation();
      if (!mounted) return;
      setState(() => _made = claim);
      messenger.showSnackBar(const SnackBar(content: Text('Compensation claimed. Kenya Airways will review it.')));
      TripScope.maybeRead(context)?.refreshQuietly();
    } catch (e) {
      if (!mounted) return;
      final message = handleApiError(context, e);
      if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final trip = widget.trip;
    final cash = trip.decision.entitlements.where((e) => e.type == 'CASH_COMPENSATION').firstOrNull;
    final claim = trip.claim('COMPENSATION') ?? _made;
    final refund = trip.claim('REFUND');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (claim != null)
        ClaimCard(claim: claim)
      else if (cash != null)
        KCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconChip(Icons.payments, color: K.amber, background: K.amberSoft),
              const SizedBox(width: K.s4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Compensation', style: t.titleMedium),
                  Text(money(cash.amount, cash.currency), style: K.dataMd(context)),
                ]),
              ),
            ]),
            const SizedBox(height: K.s3),
            Text(cash.explanation, style: t.bodyMedium),
            const SizedBox(height: K.s1),
            Text('Rule: ${cash.basis}', style: t.bodySmall?.copyWith(color: K.textSecondary)),
            const SizedBox(height: K.s4),
            if (trip.booking.isDisrupted)
              Text('You can claim once you\'ve chosen your new flight: the amount depends on when it arrives.',
                  style: t.bodySmall?.copyWith(color: K.textSecondary))
            else
              PrimaryButton(label: 'Claim compensation', busy: _busy, onPressed: _busy ? null : _claim),
          ]),
        ),
      if (refund != null) ...[
        if (claim != null || cash != null) const SizedBox(height: K.s3),
        ClaimCard(claim: refund),
      ],
    ]);
  }
}

/// "Cancel and request a refund", after the passenger confirms: it cannot be
/// undone, and the seat is released.
Future<void> confirmRefund(BuildContext context) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel and request a refund?'),
      content: const Text('Your booking is cancelled and your seat released. This can\'t be undone. '
          'Kenya Airways customer care then processes the refund of your ticket.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep my booking')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancel and refund')),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await SessionScope.read(context).api.cancelForRefund();
    messenger.showSnackBar(SnackBar(content: Text(result['message'] as String? ?? 'Your refund is requested.')));
    if (context.mounted) await TripScope.maybeRead(context)?.refresh();
  } catch (e) {
    if (!context.mounted) return;
    final message = handleApiError(context, e);
    if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}
