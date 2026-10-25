import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/skeleton.dart';

/// M13 / M14 · Vouchers and entitlements (FR-04). Every amount comes from the
/// deterministic rules engine on the server; the client only displays it,
/// from the TripStore.
class VouchersScreen extends StatelessWidget {
  const VouchersScreen({super.key});

  Future<void> _refresh(BuildContext context) async {
    try {
      await TripScope.read(context).refresh();
    } catch (e) {
      if (context.mounted) handleApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final store = TripScope.of(context);
    final trip = store.trip;
    final booking = trip?.booking;
    final decision = trip?.decision;
    final live = (trip?.vouchers ?? const <Voucher>[]).where((v) => v.isLive).toList();
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: LayoutBuilder(builder: (context, c) {
        final twoPane = c.maxWidth >= Breakpoints.twoPane;
        final vouchers = <Widget>[
          SectionHeader('Your vouchers${live.isEmpty ? '' : ' (${live.length})'}'),
          const SizedBox(height: K.s3),
          if (live.isEmpty)
            KCard(
              child: Row(children: [
                const IconChip(Icons.confirmation_number_outlined),
                const SizedBox(width: K.s4),
                Expanded(
                  child: Text(
                    booking != null && booking.isDisrupted
                        ? 'Vouchers are issued when you\'re rebooked. Choose a new flight first.'
                        : 'No vouchers have been issued for this booking.',
                    style: t.bodyMedium?.copyWith(color: K.textSecondary),
                  ),
                ),
              ]),
            ),
          for (final v in live)
            Padding(padding: const EdgeInsets.only(bottom: K.s3), child: VoucherCard(voucher: v)),
        ];
        final rules = <Widget>[
          if (decision != null) EntitlementsCard(decision: decision),
          if (decision?.regulation != null) ...[
            const SizedBox(height: K.s3),
            Text('This journey is covered by ${decision!.regulation}.',
                style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ],
        ];
        return ListView(
          padding: pagePadding(c.maxWidth, maxWidth: Breakpoints.dashboard, top: K.s5, bottom: K.s6),
          children: [
            const PageHeading(
              'Vouchers & entitlements',
              subtitle: 'Show a voucher code at the airport desk or the hotel. '
                  'Every amount comes from the rules, not from the assistant.',
            ),
            const SizedBox(height: K.s5),
            if (trip == null)
              store.failure != null && !store.loading
                  ? ErrorNotice(message: failureMessage(store.failure!), onRetry: () => _refresh(context))
                  : const ListSkeleton(label: 'Loading vouchers', item: VoucherSkeleton(), count: 2)
            else if (twoPane)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: vouchers)),
                const SizedBox(width: K.s5),
                SizedBox(
                  width: 380,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rules),
                ),
              ])
            else ...[
              ...vouchers,
              const SizedBox(height: K.s4),
              ...rules,
            ],
          ],
        );
      }),
    );
  }
}
