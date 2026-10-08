import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// M15 · Hand-off to a person (FR-05). The case already holds the booking and
/// the reason, so the passenger does not have to start again with the agent.
class HandoffScreen extends StatefulWidget {
  const HandoffScreen({super.key, this.initial});
  final HandoffCase? initial;

  @override
  State<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends State<HandoffScreen> {
  List<HandoffCase>? _cases;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final cases = await SessionScope.read(context).api.myCases();
      if (mounted) setState(() => _cases = cases);
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      setState(() => _error = msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final current = widget.initial;
    final others = (_cases ?? const <HandoffCase>[])
        .where((c) => current == null || c.id != current.id)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Talk to a person')),
      body: ListView(
        padding: const EdgeInsets.all(K.s4),
        children: [
          if (current != null) ...[
            Semantics(
              liveRegion: true,
              child: Text('We\'ve passed your case to our team', style: t.headlineSmall),
            ),
            const SizedBox(height: K.s4),
            HandoffCard(handoff: current),
            const SizedBox(height: K.s5),
          ],
          const SectionLabel('What happens next'),
          const SizedBox(height: K.s2),
          for (final (i, step) in const [
            'A Kenya Airways agent picks up your case from the disruption desk queue.',
            'They can see your booking, what Kestrel already did, and why it handed over.',
            'They contact you on the details in your booking.',
          ].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: K.s3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: K.elevated,
                  child: Text('${i + 1}', style: K.label(context)),
                ),
                const SizedBox(width: K.s3),
                Expanded(child: Text(step, style: t.bodyMedium)),
              ]),
            ),
          if (_error != null) ErrorNotice(message: _error!, onRetry: _load),
          if (others.isNotEmpty) ...[
            const SizedBox(height: K.s4),
            const SectionLabel('Your other cases'),
            const SizedBox(height: K.s2),
            for (final c in others)
              Padding(
                padding: const EdgeInsets.only(bottom: K.s3),
                child: HandoffCard(handoff: c),
              ),
          ],
          const SizedBox(height: K.s4),
          PrimaryButton(
            label: 'Back to chat',
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
          ),
        ],
      ),
    );
  }
}
