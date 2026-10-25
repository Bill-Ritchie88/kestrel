import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/skeleton.dart';
import 'help_screen.dart';

/// Help section of the passenger app: the help centre (search, topics,
/// questions), and beside it the way to a person - M15 hand-off (FR-05). A
/// case already holds the booking and the reason, so the passenger does not
/// have to start again.
class HandoffScreen extends StatefulWidget {
  const HandoffScreen({super.key, required this.onPerson});
  final VoidCallback onPerson;

  @override
  State<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends State<HandoffScreen> {
  /// The passenger's cases come with the trip (TripStore).
  Future<void> _load() async {
    try {
      await TripScope.read(context).refresh();
    } catch (e) {
      if (mounted) handleApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, c) => ListView(
          padding: pagePadding(c.maxWidth, maxWidth: Breakpoints.dashboard, top: 0, bottom: K.s6),
          children: [
            HelpCentre(stillStuck: _support(context)),
            Text(disclaimer, style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ],
        ),
      ),
    );
  }

  /// The person-to-talk-to panel: the case just opened, the way to open one,
  /// what happens next, and the passenger's other cases.
  Widget _support(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final shell = ShellScope.of(context);
    final store = TripScope.of(context);
    final latest = shell.latestCase;
    final loaded = store.trip?.cases;
    final error =
        loaded == null && store.failure != null && !store.loading ? failureMessage(store.failure!) : null;
    final cases = loaded ?? const <HandoffCase>[];
    final others = cases.where((c) => latest == null || c.id != latest.id).toList();
    final hasOpen = (latest?.isOpen ?? false) || cases.any((c) => c.isOpen);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (latest != null) ...[
        Semantics(
          liveRegion: true,
          child: const InfoBanner(text: 'We\'ve passed your case to our team.', icon: Icons.check_circle_outline),
        ),
        const SizedBox(height: K.s3),
        HandoffCard(handoff: latest),
        const SizedBox(height: K.s4),
      ],
      KCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.headset_mic_outlined, color: K.sky, size: 28),
          const SizedBox(height: K.s3),
          Semantics(
            header: true,
            child: Text(hasOpen ? 'A person has your case' : 'Still stuck?',
                style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: K.s2),
          Text(
            hasOpen
                ? 'Our disruption desk sees your booking and what Kestrel already did. They will contact you.'
                : 'The disruption desk can handle special assistance, group bookings and anything the '
                    'assistant cannot.',
            style: t.bodyMedium?.copyWith(color: K.textSecondary),
          ),
          if (!hasOpen) ...[
            const SizedBox(height: K.s4),
            PrimaryButton(
              label: 'Talk to a person',
              icon: Icons.support_agent,
              busy: shell.requestingPerson,
              onPressed: widget.onPerson,
              height: 48,
              expand: false,
            ),
          ],
          const Divider(height: K.s6),
          Semantics(header: true, child: Text('What happens next', style: t.titleMedium)),
          const SizedBox(height: K.s3),
          for (final (i, step) in const [
            'A Kenya Airways agent picks up your case from the disruption desk queue.',
            'They can see your booking, what Kestrel already did, and why it handed over.',
            'They contact you on the details in your booking.',
          ].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: K.s3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(gradient: K.primaryGradient, shape: BoxShape.circle),
                  child: Text('${i + 1}', style: K.label(context).copyWith(color: Colors.white, fontSize: 12)),
                ),
                const SizedBox(width: K.s3),
                Expanded(child: Text(step, style: t.bodyMedium)),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: K.s5),
      SectionHeader(latest == null ? 'Your cases' : 'Your other cases'),
      const SizedBox(height: K.s3),
      if (error != null) ErrorNotice(message: error, onRetry: _load),
      if (loaded == null && error == null)
        const ListSkeleton(label: 'Loading your cases', item: VoucherSkeleton(), count: 1),
      if (loaded != null && others.isEmpty)
        Text(
          latest == null ? 'You haven\'t asked for a person yet.' : 'No other cases.',
          style: t.bodyMedium?.copyWith(color: K.textSecondary),
        ),
      for (final c in others)
        Padding(padding: const EdgeInsets.only(bottom: K.s3), child: HandoffCard(handoff: c)),
    ]);
  }
}
