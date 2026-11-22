import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/claims.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';

/// Migration 016 · The staff desk's Compensation tab. Claims newest first;
/// a CLAIMED one is approved or rejected (with a reason), an APPROVED one is
/// marked paid with the payout reference entered here (no money moves
/// through Kestrel). The server refuses any other move with a 409.
class StaffClaimsView extends StatefulWidget {
  const StaffClaimsView({super.key, this.phone = false});
  final bool phone;

  @override
  State<StaffClaimsView> createState() => _StaffClaimsViewState();
}

class _StaffClaimsViewState extends State<StaffClaimsView> {
  List<Claim>? _claims;
  String? _error;
  bool _openOnly = true;
  int? _busyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final claims = await SessionScope.read(context).api.staffClaims();
      if (mounted) setState(() => _claims = claims);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _move(Claim c, Future<Claim> Function(String by) step, String done) async {
    final session = SessionScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyId = c.id);
    try {
      final updated = await step(session.staffName ?? 'staff');
      if (!mounted) return;
      setState(() => _claims = [for (final x in _claims ?? <Claim>[]) x.id == c.id ? updated : x]);
      messenger.showSnackBar(SnackBar(content: Text('Claim #${c.id} $done.')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      if (e.status == 409) _load(); // someone else moved it first
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<String?> _ask(String title, String label) => showDialog<String>(
        context: context,
        builder: (context) {
          final text = TextEditingController();
          return AlertDialog(
            title: Text(title),
            content: TextField(
              key: const ValueKey('claim-text'),
              controller: text,
              autofocus: true,
              decoration: InputDecoration(labelText: label),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(
                onPressed: () {
                  if (text.text.trim().isNotEmpty) Navigator.pop(context, text.text.trim());
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );

  Future<void> _reject(Claim c) async {
    final reason = await _ask('Reject claim #${c.id}', 'Reason (shown to the passenger)');
    if (reason == null || !mounted) return;
    final api = SessionScope.read(context).api;
    await _move(c, (by) => api.rejectClaim(c.id, by: by, reason: reason), 'rejected');
  }

  Future<void> _pay(Claim c) async {
    final ref = await _ask('Mark claim #${c.id} paid', 'Payout reference');
    if (ref == null || !mounted) return;
    final api = SessionScope.read(context).api;
    await _move(c, (by) => api.payClaim(c.id, by: by, reference: ref), 'marked paid');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final all = _claims ?? const <Claim>[];
    final visible = _openOnly ? all.where((c) => c.status == 'CLAIMED' || c.status == 'APPROVED').toList() : all;
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(builder: (context, c) {
        return ListView(
          padding: pagePadding(c.maxWidth, maxWidth: 1000, top: widget.phone ? K.s4 : 28, bottom: K.s6),
          children: [
            const PageHeading('Compensation',
                subtitle: 'Claims passengers made for the compensation the rules give, and refund requests. '
                    'Approve or reject each one, then record the payout.'),
            const SizedBox(height: K.s4),
            Wrap(spacing: K.s2, children: [
              ChoiceChip(
                  label: const Text('To do'), selected: _openOnly, onSelected: (_) => setState(() => _openOnly = true)),
              ChoiceChip(
                  label: const Text('All claims'),
                  selected: !_openOnly,
                  onSelected: (_) => setState(() => _openOnly = false)),
            ]),
            const SizedBox(height: K.s4),
            if (_error != null) ErrorNotice(message: _error!, onRetry: _load),
            if (_claims == null && _error == null) const Loading('Loading claims'),
            if (_claims != null && visible.isEmpty)
              Text(_openOnly ? 'No claims waiting.' : 'No claims yet.',
                  style: t.bodyMedium?.copyWith(color: K.textSecondary)),
            for (final claim in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: K.s3),
                child: KCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          '#${claim.id} · ${claim.pnr}'
                          '${claim.passengerName.isEmpty ? '' : ' · ${claim.passengerName}'}',
                          style: t.titleMedium,
                        ),
                      ),
                      StatusPill(claim.status),
                    ]),
                    const SizedBox(height: K.s1),
                    Text(
                      '${claim.isRefund ? 'Refund of the ticket' : 'Compensation ${money(claim.amount, claim.currency)}'}'
                      ' · ${claim.basis}',
                      style: t.bodyMedium,
                    ),
                    const SizedBox(height: K.s1),
                    Text(ClaimCard.statusLine(claim), style: t.bodySmall?.copyWith(color: K.textSecondary)),
                    if (claim.status == 'CLAIMED' || claim.status == 'APPROVED') ...[
                      const SizedBox(height: K.s3),
                      Wrap(spacing: K.s2, runSpacing: K.s2, children: [
                        if (claim.status == 'CLAIMED') ...[
                          SecondaryButton(
                            label: 'Approve',
                            icon: Icons.check,
                            height: 44,
                            expand: false,
                            onPressed: _busyId == claim.id
                                ? null
                                : () => _move(
                                    claim,
                                    (by) => SessionScope.read(context).api.approveClaim(claim.id, by: by),
                                    'approved'),
                          ),
                          SecondaryButton(
                            label: 'Reject',
                            icon: Icons.close,
                            height: 44,
                            expand: false,
                            onPressed: _busyId == claim.id ? null : () => _reject(claim),
                          ),
                        ],
                        if (claim.status == 'APPROVED')
                          SecondaryButton(
                            label: 'Mark paid',
                            icon: Icons.payments,
                            height: 44,
                            expand: false,
                            onPressed: _busyId == claim.id ? null : () => _pay(claim),
                          ),
                      ]),
                    ],
                  ]),
                ),
              ),
          ],
        );
      }),
    );
  }
}
