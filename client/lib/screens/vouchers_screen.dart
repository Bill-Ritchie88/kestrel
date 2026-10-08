import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// M13 / M14 · Entitlements and vouchers (FR-04). Every amount comes from the
/// deterministic rules engine on the server; the client only displays it.
class VouchersScreen extends StatefulWidget {
  const VouchersScreen({super.key});

  @override
  State<VouchersScreen> createState() => _VouchersScreenState();
}

class _VouchersScreenState extends State<VouchersScreen> {
  EntitlementDecision? _decision;
  List<Voucher> _vouchers = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await SessionScope.read(context).api.entitlements();
      if (mounted) {
        setState(() {
          _decision = r.decision;
          _vouchers = r.vouchers.where((v) => v.isLive).toList();
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final booking = SessionScope.of(context).booking;
    return Scaffold(
      appBar: AppBar(title: const Text('Vouchers & entitlements')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(K.s4),
          children: [
            if (_loading && _decision == null)
              const Padding(
                padding: EdgeInsets.all(K.s6),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null) ErrorNotice(message: _error!, onRetry: _load),
            if (_decision != null) ...[
              const SectionLabel('Vouchers'),
              const SizedBox(height: K.s2),
              if (_vouchers.isEmpty)
                Text(
                  booking != null && booking.isDisrupted
                      ? 'Vouchers are issued when you\'re rebooked. Choose a new flight first.'
                      : 'No vouchers have been issued for this booking.',
                  style: t.bodyMedium?.copyWith(color: K.textSecondary),
                ),
              for (final v in _vouchers)
                Padding(
                  padding: const EdgeInsets.only(bottom: K.s3),
                  child: VoucherCard(voucher: v),
                ),
              const SizedBox(height: K.s4),
              EntitlementsCard(decision: _decision!),
              if (_decision!.regulation != null) ...[
                const SizedBox(height: K.s3),
                Text('This journey is covered by ${_decision!.regulation}.',
                    style: t.bodySmall?.copyWith(color: K.textSecondary)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
