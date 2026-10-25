import 'package:flutter/material.dart';

import '../state/public.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/google_logo.dart';
import '../widgets/public.dart';

/// The public Home page, shown when nobody is signed in (01-Home,
/// 14-Phone-Home): what Kestrel does, a booking-reference form that signs
/// straight in, how it works, how answers are grounded, and the FAQ.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();
  final _pnrFocus = FocusNode();
  final _anchors = {for (final a in HomeAnchor.values) a: GlobalKey()};

  @override
  void initState() {
    super.initState();
    final pending = PublicScope.read(context).takeAnchor();
    if (pending != null) WidgetsBinding.instance.addPostFrameCallback((_) => _jump(pending));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _pnrFocus.dispose();
    super.dispose();
  }

  Future<void> _jump(HomeAnchor a) async {
    final target = _anchors[a]!.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
    if (a == HomeAnchor.booking && mounted) _pnrFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: K.base,
      body: Column(children: [
        PublicHeader(onAnchor: _jump),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= 900;
            return SingleChildScrollView(
              controller: _scroll,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _Hero(wide: wide, bookingKey: _anchors[HomeAnchor.booking]!, pnrFocus: _pnrFocus, onFind: () => _jump(HomeAnchor.booking)),
                _Facts(wide: wide),
                KeyedSubtree(key: _anchors[HomeAnchor.howItWorks], child: _HowItWorks(wide: wide)),
                KeyedSubtree(key: _anchors[HomeAnchor.rights], child: _Rights(wide: wide)),
                const _Handover(),
                KeyedSubtree(key: _anchors[HomeAnchor.faq], child: const _Questions()),
                const PublicFooter(),
              ]),
            );
          }),
        ),
      ]),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.wide, required this.bookingKey, required this.pnrFocus, required this.onFind});
  final bool wide;
  final GlobalKey bookingKey;
  final FocusNode pnrFocus;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final public = PublicScope.read(context);
    final headline = t.displaySmall?.copyWith(
      fontSize: wide ? 56 : 38,
      height: 1.05,
      letterSpacing: -1.2,
      fontWeight: FontWeight.w800,
    );
    final copy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: K.crimsonSoft,
          border: Border.all(color: K.crimsonStroke),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text('DISRUPTION RECOVERY', style: K.mono(fontSize: 11, letterSpacing: 1.4, color: K.glow)),
      ),
      const SizedBox(height: K.s5),
      Semantics(
        header: true,
        child: Text.rich(
          const TextSpan(children: [
            TextSpan(text: 'Cancelled flight.\n'),
            TextSpan(text: 'New seat in minutes.', style: TextStyle(color: K.textSecondary)),
          ]),
          style: headline,
        ),
      ),
      const SizedBox(height: K.s5),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Text(
          'Kestrel rebooks you on the next available flight, issues meal and hotel vouchers, and answers with '
          'the exact policy clause — day or night.',
          style: t.bodyLarge?.copyWith(color: K.textSecondary, fontSize: wide ? 17 : 16),
        ),
      ),
      if (wide) ...[
        const SizedBox(height: K.s6),
        Wrap(spacing: K.s3, runSpacing: K.s3, children: [
          PrimaryButton(label: 'Find my booking', icon: Icons.arrow_forward, onPressed: onFind, height: 52, expand: false),
          SecondaryButton(
            label: 'Sign in with Google or email',
            onPressed: () => public.signIn(),
            height: 52,
            expand: false,
          ),
        ]),
      ],
    ]);

    final form = KeyedSubtree(
      key: bookingKey,
      child: Container(
        padding: EdgeInsets.all(wide ? K.s5 : K.s4),
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GuestBookingForm(horizontal: wide, pnrFocus: pnrFocus),
          const SizedBox(height: K.s3),
          if (wide)
            Text('No account needed. Your booking reference is the 6-character code on your e-ticket.',
                style: t.bodySmall?.copyWith(color: K.textSecondary))
          else ...[
            const _OrDivider(),
            const SizedBox(height: K.s3),
            Row(children: [
              Expanded(
                child: _AccountButton(label: 'Google', leading: const GoogleLogo(), onPressed: () => public.signIn()),
              ),
              const SizedBox(width: K.s3),
              Expanded(
                child: _AccountButton(
                  label: 'Email',
                  leading: const Icon(Icons.mail_outline, size: 18),
                  onPressed: () => public.signIn(),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.9, -1.1),
          radius: 1.2,
          colors: [Color(0x40A81030), K.base],
        ),
      ),
      padding: EdgeInsets.only(top: wide ? 72 : K.s6, bottom: wide ? 56 : K.s6),
      child: PublicSection(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: copy),
              const SizedBox(width: 56),
              const Expanded(child: _ExampleBooking()),
            ])
          else
            copy,
          SizedBox(height: wide ? 56 : K.s5),
          form,
        ]),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Row(children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: K.s3),
            child: Text('OR', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.textSecondary)),
          ),
          const Expanded(child: Divider()),
        ]),
      );
}

class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.label, required this.leading, required this.onPressed});
  final String label;
  final Widget leading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: K.textPrimary,
          backgroundColor: K.elevated,
          minimumSize: const Size(K.touch, 50),
          side: const BorderSide(color: K.hairline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          leading,
          const SizedBox(width: K.s2),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ]),
      );
}

/// The illustration beside the hero on a laptop: what a recovered booking
/// looks like. Synthetic data, labelled as an example.
class _ExampleBooking extends StatelessWidget {
  const _ExampleBooking();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    TextStyle mono([Color color = K.textPrimary]) => K.mono(fontSize: 12.5, color: color);
    Widget row(List<String> cells, {Color? status, bool strike = false, bool highlight = false}) => Container(
          margin: const EdgeInsets.only(top: K.s2),
          padding: const EdgeInsets.symmetric(horizontal: K.s3, vertical: 10),
          decoration: BoxDecoration(
            color: highlight ? K.tealSoft : null,
            borderRadius: BorderRadius.circular(8),
            border: highlight ? Border.all(color: K.teal.withAlpha(120)) : null,
          ),
          child: Row(children: [
            Expanded(flex: 2, child: Text(cells[0], style: mono())),
            Expanded(
              flex: 3,
              child: Text(cells[1],
                  style: mono(K.textSecondary).copyWith(decoration: strike ? TextDecoration.lineThrough : null)),
            ),
            Expanded(flex: 2, child: Text(cells[2], style: mono(K.textSecondary))),
            Expanded(
              flex: 3,
              child: Text(cells[3], textAlign: TextAlign.right, style: mono(status ?? K.textSecondary)),
            ),
          ]),
        );
    return Semantics(
      label: 'Example: a cancelled flight KQ886 Nairobi to Bangkok on 15 October, rebooked on 16 October in seat 21A, '
          'with a meal voucher and a hotel night issued.',
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 20))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(K.s4, K.s3, K.s4, K.s3),
            child: Row(children: [
              Text('BOOKING A27Z99', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.textSecondary)),
              const Spacer(),
              Text('EXAMPLE', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.teal)),
            ]),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(K.s3, K.s3, K.s3, K.s2),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: K.s3),
                child: Row(children: [
                  for (final (h, flex, align) in const [
                    ('FLIGHT', 2, TextAlign.left),
                    ('ROUTE', 3, TextAlign.left),
                    ('DEP', 2, TextAlign.left),
                    ('STATUS', 3, TextAlign.right),
                  ])
                    Expanded(
                      flex: flex,
                      child: Text(h, textAlign: align, style: K.mono(fontSize: 10, letterSpacing: 1, color: K.textSecondary)),
                    ),
                ]),
              ),
              row(['KQ886', 'NBO → BKK', '15 OCT', 'CANCELLED'], status: K.glow, strike: true),
              row(['KQ886', 'NBO → BKK', '16 OCT', 'SEAT 21A'], status: K.teal, highlight: true),
              row(['MEAL', 'Voucher', 'KES', '2,500']),
              row(['HOTEL', '1 night · NBO', '—', 'ISSUED']),
            ]),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(K.s4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.auto_awesome, size: 14, color: K.glow),
              const SizedBox(width: K.s2),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Rebooked on the earliest arrival in your cabin. Care is owed while you wait — '),
                    TextSpan(text: 'KQ CoC Art. 9', style: K.mono(fontSize: 12, color: K.textSecondary)),
                  ]),
                  style: t.bodySmall?.copyWith(color: K.textPrimary),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.wide});
  final bool wide;

  static const _items = [
    ('< 10 s', 'target time to answer each message'),
    ('0', 'double-booked seats, by database design'),
    ('120', 'policy clauses the assistant can cite'),
    ('24 / 7', 'with a person one tap away'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget fact((String, String) f) => Semantics(
          label: '${f.$1} ${f.$2}',
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f.$1, style: K.mono(fontSize: wide ? 26 : 22, fontWeight: FontWeight.w700, color: K.textPrimary)),
            const SizedBox(height: K.s1),
            Text(f.$2, style: t.bodySmall?.copyWith(color: K.textSecondary)),
          ]),
        );
    return Container(
      decoration: const BoxDecoration(border: Border.symmetric(horizontal: BorderSide(color: K.hairline))),
      padding: EdgeInsets.symmetric(vertical: wide ? K.s6 : K.s5),
      child: PublicSection(
        child: wide
            ? Row(children: [for (final f in _items) Expanded(child: fact(f))])
            : LayoutBuilder(
                builder: (context, c) {
                  final w = (c.maxWidth - K.s3) / 2;
                  return Wrap(spacing: K.s3, runSpacing: K.s3, children: [
                    for (final f in _items)
                      Container(
                        width: w,
                        padding: const EdgeInsets.all(K.s4),
                        decoration: BoxDecoration(
                          color: K.surface,
                          borderRadius: BorderRadius.circular(K.radius),
                          border: Border.all(color: K.hairline),
                        ),
                        child: fact(f),
                      ),
                  ]);
                },
              ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.wide});
  final bool wide;

  static const _steps = [
    (Icons.search, 'Find your booking', 'Reference and surname, or sign in. See exactly what happened to your flight and why.'),
    (Icons.flight_takeoff, 'Choose a new flight',
        'Same route and cabin, earliest arrival first. Confirming locks the seat in one atomic step.'),
    (Icons.confirmation_number_outlined, 'Collect your vouchers',
        'Meal, hotel, transfer and Asante Rewards points arrive with your new booking.'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget step(int i) {
      final (icon, title, body) = _steps[i];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('STEP ${i + 1}', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.textSecondary)),
        const SizedBox(height: K.s3),
        ExcludeSemantics(child: Icon(icon, color: K.glow, size: 22)),
        const SizedBox(height: K.s3),
        Text(title, style: t.titleLarge?.copyWith(fontSize: 19)),
        const SizedBox(height: K.s2),
        Text(body, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
      ]);
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: wide ? 88 : 56),
      child: PublicSection(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Kicker('01 — How it works'),
          const SizedBox(height: K.s3),
          Semantics(
            header: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                wide ? 'From cancelled to confirmed in three steps' : 'Three steps from cancelled to confirmed',
                style: t.headlineSmall?.copyWith(fontSize: wide ? 34 : 26, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: K.s6),
          if (wide)
            Container(
              decoration: BoxDecoration(
                color: K.surface,
                borderRadius: BorderRadius.circular(K.radiusLg),
                border: Border.all(color: K.hairline),
              ),
              child: IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < _steps.length; i++) ...[
                    if (i > 0) const VerticalDivider(width: 1),
                    Expanded(child: Padding(padding: const EdgeInsets.all(K.s5), child: step(i))),
                  ],
                ]),
              ),
            )
          else
            Column(children: [
              for (var i = 0; i < _steps.length; i++) ...[
                if (i > 0) const Divider(height: K.s6),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  IconChip(_steps[i].$1, size: 40),
                  const SizedBox(width: K.s4),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('STEP ${i + 1}', style: K.mono(fontSize: 11, letterSpacing: 1, color: K.textSecondary)),
                      const SizedBox(height: K.s1),
                      Text(_steps[i].$2, style: t.titleMedium?.copyWith(fontSize: 18)),
                      const SizedBox(height: K.s1),
                      Text(_steps[i].$3, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
                    ]),
                  ),
                ]),
              ],
            ]),
        ]),
      ),
    );
  }
}

class _Rights extends StatelessWidget {
  const _Rights({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final copy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Kicker('02 — Your rights'),
      const SizedBox(height: K.s3),
      Semantics(
        header: true,
        child: Text('Every answer shows its source',
            style: t.headlineSmall?.copyWith(fontSize: wide ? 34 : 26, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: K.s4),
      Text(
        'The AI explains; fixed rules decide. Amounts come from your route, the disruption cause and your wait — '
        'never from a guess. If no clause covers your question, Kestrel says so and offers a person.',
        style: t.bodyLarge?.copyWith(color: K.textSecondary),
      ),
    ]);
    Widget chip(String text, {bool match = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: match ? K.tealSoft : K.inset,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: match ? K.teal.withAlpha(120) : K.hairline),
          ),
          child: Text(text, style: K.mono(fontSize: 11.5, color: match ? K.teal : K.textSecondary)),
        );
    final example = Semantics(
      label: 'Example answer. Question: Do I get a hotel if the new flight is tomorrow? Answer: Yes. When your new '
          'departure is the next day, Kenya Airways provides a hotel night and transfers between the airport and '
          'the hotel. Sources: KQ Conditions of Carriage article 9.2, EU261 article 9(1)(b), match 0.86.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(K.s4),
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(K.radiusLg),
          border: Border.all(color: K.hairline),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: K.s3, vertical: 10),
              decoration: BoxDecoration(color: K.elevated, borderRadius: BorderRadius.circular(12)),
              child: Text('Do I get a hotel if the new flight is tomorrow?', style: t.bodyMedium),
            ),
          ),
          const SizedBox(height: K.s3),
          Container(
            padding: const EdgeInsets.all(K.s4),
            decoration: BoxDecoration(
              color: K.inset,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: K.hairline),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Yes. When your new departure is the next day, Kenya Airways provides a hotel night and transfers '
                'between the airport and the hotel.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: K.s3),
              Wrap(spacing: K.s2, runSpacing: K.s2, children: [
                chip('KQ CoC Art. 9.2'),
                chip('EU261 Art. 9(1)(b)'),
                chip('match 0.86', match: true),
              ]),
            ]),
          ),
        ]),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: wide ? 88 : 56),
      child: PublicSection(
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: copy),
                const SizedBox(width: 56),
                Expanded(child: example),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [copy, const SizedBox(height: K.s5), example]),
      ),
    );
  }
}

class _Handover extends StatelessWidget {
  const _Handover();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final public = PublicScope.read(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 88),
      child: PublicSection(
        child: Container(
          padding: const EdgeInsets.all(K.s5),
          decoration: BoxDecoration(
            color: K.surface,
            borderRadius: BorderRadius.circular(K.radiusLg),
            border: Border.all(color: K.hairline),
          ),
          child: LayoutBuilder(builder: (context, c) {
            final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text('A person takes over whenever you ask', style: t.titleLarge)),
              const SizedBox(height: K.s1),
              Text('The disruption desk sees your booking and your last question, so you don\'t start again.',
                  style: t.bodyMedium?.copyWith(color: K.textSecondary)),
            ]);
            // A person needs to know whose trip it is: sign in first.
            final button = SecondaryButton(
              label: 'Talk to a person',
              onPressed: () => public.signIn(),
              height: 48,
              expand: c.maxWidth < 640,
            );
            return c.maxWidth >= 640
                ? Row(children: [Expanded(child: text), const SizedBox(width: K.s5), button])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [text, const SizedBox(height: K.s4), button]);
          }),
        ),
      ),
    );
  }
}

class _Questions extends StatelessWidget {
  const _Questions();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 88),
      child: PublicSection(
        maxWidth: 760,
        child: Column(children: [
          const Kicker('03 — Help'),
          const SizedBox(height: K.s3),
          Semantics(
            header: true,
            child: Text('Questions passengers ask',
                textAlign: TextAlign.center,
                style: t.headlineSmall?.copyWith(fontSize: 30, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: K.s5),
          FaqList(items: faqs.take(4).toList()),
          const SizedBox(height: K.s3),
          LinkButton(label: 'More questions in Help', onPressed: PublicScope.read(context).goHelp),
        ]),
      ),
    );
  }
}
