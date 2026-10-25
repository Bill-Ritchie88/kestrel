import 'package:flutter/material.dart';

import '../state/public.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/public.dart';

const _topics = [
  (FaqTopic.rebooking, Icons.sync, 'Rebooking', 'New flights, seats and what \'same route\' means.'),
  (FaqTopic.vouchers, Icons.confirmation_number_outlined, 'Vouchers', 'Meals, hotel nights, transfers and where to use them.'),
  (FaqTopic.rights, Icons.description_outlined, 'Refunds and rights', 'When you can claim a refund or compensation.'),
  (FaqTopic.accounts, Icons.people_outline, 'Accounts and sign-in', 'Google, email codes and linking bookings.'),
];

/// The help centre (10-Help): search, topics and questions, with
/// [stillStuck] beside them - the way to a person. Used by the public Help
/// page and by the passenger app's Help section. It does not scroll by
/// itself; the page around it does.
class HelpCentre extends StatefulWidget {
  const HelpCentre({super.key, required this.stillStuck});
  final Widget stillStuck;

  @override
  State<HelpCentre> createState() => _HelpCentreState();
}

class _HelpCentreState extends State<HelpCentre> {
  final _search = TextEditingController();
  FaqTopic? _topic;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Faq> get _matches {
    final words = _search.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    return faqs.where((f) {
      if (_topic != null && f.topic != _topic) return false;
      final text = '${f.question} ${f.answer}'.toLowerCase();
      return words.every(text.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final matches = _matches;
    final filtered = _topic != null || _search.text.trim().isNotEmpty;
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 900;
      final topicWidth = c.maxWidth >= 1000
          ? (c.maxWidth - 3 * K.s4) / 4
          : c.maxWidth >= 560
              ? (c.maxWidth - K.s4) / 2
              : c.maxWidth;
      final questions = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(filtered ? 'Matching questions' : 'Popular questions',
                  style: t.headlineSmall?.copyWith(fontSize: 26, fontWeight: FontWeight.w700)),
            ),
          ),
          if (filtered)
            TextButton(
              onPressed: () => setState(() {
                _topic = null;
                _search.clear();
              }),
              style: TextButton.styleFrom(foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
              child: const Text('Show all'),
            ),
        ]),
        const SizedBox(height: K.s4),
        if (matches.isEmpty)
          Semantics(
            liveRegion: true,
            child: Text(
              'No questions match that. Try other words, or talk to a person.',
              style: t.bodyMedium?.copyWith(color: K.textSecondary),
            ),
          )
        else
          FaqList(
            key: ValueKey('${_topic?.name}|${_search.text}'),
            items: matches,
            initiallyOpen: filtered ? null : 0,
          ),
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: K.s6),
        const Center(child: Kicker('Help centre')),
        const SizedBox(height: K.s3),
        Semantics(
          header: true,
          child: Text('How can we help?',
              textAlign: TextAlign.center,
              style: t.displaySmall?.copyWith(fontSize: wide ? 46 : 32, fontWeight: FontWeight.w800, letterSpacing: -1)),
        ),
        const SizedBox(height: K.s5),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search: refunds, hotel vouchers, missed connection…',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
        ),
        const SizedBox(height: 48),
        Wrap(spacing: K.s4, runSpacing: K.s4, children: [
          for (final (topic, icon, title, body) in _topics)
            SizedBox(
              width: topicWidth,
              child: _TopicCard(
                icon: icon,
                title: title,
                body: body,
                selected: _topic == topic,
                onTap: () => setState(() => _topic = _topic == topic ? null : topic),
              ),
            ),
        ]),
        const SizedBox(height: 48),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: questions),
            const SizedBox(width: 48),
            SizedBox(width: 420, child: widget.stillStuck),
          ])
        else ...[
          questions,
          const SizedBox(height: K.s6),
          widget.stillStuck,
        ],
        const SizedBox(height: K.s6),
      ]);
    });
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({required this.icon, required this.title, required this.body, required this.selected, required this.onTap});
  final IconData icon;
  final String title, body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $body',
      excludeSemantics: true,
      child: Material(
        color: selected ? K.elevated : K.surface,
        borderRadius: BorderRadius.circular(K.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(K.radius),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 140),
            padding: const EdgeInsets.all(K.s5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(K.radius),
              border: Border.all(color: selected ? K.glow : K.hairline, width: selected ? 1.5 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: K.glow, size: 22),
              const SizedBox(height: K.s3),
              Text(title, style: t.titleMedium?.copyWith(fontSize: 17)),
              const SizedBox(height: K.s2),
              Text(body, style: t.bodySmall?.copyWith(color: K.textSecondary, height: 1.5)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Still stuck?" for someone not signed in: a person needs the booking
/// first, so the button leads to sign-in.
class _PublicStillStuck extends StatelessWidget {
  const _PublicStillStuck();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return KCard(
      padding: const EdgeInsets.all(K.s6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.headset_mic_outlined, color: K.sky, size: 28),
        const SizedBox(height: K.s4),
        Semantics(header: true, child: Text('Still stuck?', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
        const SizedBox(height: K.s3),
        Text(
          'The disruption desk can handle special assistance, group bookings and anything the assistant cannot.',
          style: t.bodyMedium?.copyWith(color: K.textSecondary),
        ),
        const SizedBox(height: K.s5),
        PrimaryButton(
          label: 'Talk to a person',
          onPressed: () => PublicScope.read(context).signIn(),
          height: 48,
          expand: false,
        ),
        const SizedBox(height: K.s3),
        Text('Sign in or use your booking reference first, so the desk can see your trip.',
            style: t.bodySmall?.copyWith(color: K.textSecondary)),
      ]),
    );
  }
}

/// The public Help page, reachable from Home.
class PublicHelpScreen extends StatelessWidget {
  const PublicHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: K.base,
      body: Column(children: [
        PublicHeader(helpSelected: true),
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PublicSection(child: HelpCentre(stillStuck: _PublicStillStuck())),
              PublicFooter(),
            ]),
          ),
        ),
      ]),
    );
  }
}
