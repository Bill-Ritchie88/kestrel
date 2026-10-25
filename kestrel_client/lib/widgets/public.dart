import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/kestrel_api.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../theme.dart';
import 'common.dart';

/// Pieces shared by the public pages (Home, Help, sign-in, system states).

/// Page gutters and widths for the public site.
const publicMaxWidth = 1200.0;
double publicGutter(double width) => width >= 760 ? K.s5 : K.s4;

/// Centres [child] at the public site's width with the right gutter.
class PublicSection extends StatelessWidget {
  const PublicSection({super.key, required this.child, this.maxWidth = publicMaxWidth});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final side = math.max(publicGutter(c.maxWidth), (c.maxWidth - maxWidth) / 2);
          return Padding(padding: EdgeInsets.symmetric(horizontal: side), child: child);
        },
      );
}

/// The crimson tile with the plane, and "Kestrel".
class PublicLogo extends StatelessWidget {
  const PublicLogo({super.key, this.prototypeTag = true});
  final bool prototypeTag;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Kestrel, disruption assistant${prototypeTag ? ', prototype' : ''}',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            gradient: K.primaryGradient,
            borderRadius: BorderRadius.circular(9),
            boxShadow: const [BoxShadow(color: Color(0x55FF2E55), blurRadius: 14)],
          ),
          child: Transform.rotate(angle: math.pi / 4, child: const Icon(Icons.flight, size: 19, color: Colors.white)),
        ),
        const SizedBox(width: K.s3),
        Text('Kestrel', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (prototypeTag) ...[
          const SizedBox(width: K.s2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: K.hairline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('PROTOTYPE', style: K.mono(fontSize: 10, letterSpacing: 1, color: K.textSecondary)),
          ),
        ],
      ]),
    );
  }
}

/// "01 — HOW IT WORKS" above a section heading.
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: K.mono(fontSize: 12, letterSpacing: 1.6, color: K.glow));
}

/// Top bar of the public site: logo, section links, Sign in, Manage booking.
/// On a phone the links move into a menu.
class PublicHeader extends StatelessWidget {
  const PublicHeader({super.key, this.onAnchor, this.helpSelected = false});

  /// When set, the How it works / Your rights / Manage booking links scroll
  /// this page; otherwise they open Home at that section.
  final ValueChanged<HomeAnchor>? onAnchor;
  final bool helpSelected;

  @override
  Widget build(BuildContext context) {
    final public = PublicScope.read(context);
    void anchor(HomeAnchor a) => onAnchor != null ? onAnchor!(a) : public.goHome(a);
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: const BoxDecoration(
        color: K.base,
        border: Border(bottom: BorderSide(color: K.hairline)),
      ),
      child: SafeArea(
        bottom: false,
        child: PublicSection(
          child: SizedBox(
            height: 68,
            child: LayoutBuilder(builder: (context, c) {
              // The full bar only when everything in it fits at the current
              // text size; otherwise (a phone, or very large text) the links
              // move into the menu rather than overlapping.
              final wide = c.maxWidth >= _fullBarWidth(context);
              // On a very narrow screen or with very large text even "Sign in"
              // moves into the menu.
              final roomForSignIn = wide || c.maxWidth >= _compactBarWidth(context);
              Widget link(String label, VoidCallback onTap, {bool selected = false}) => TextButton(
                    onPressed: onTap,
                    style: TextButton.styleFrom(
                      foregroundColor: selected ? K.textPrimary : K.textSecondary,
                      minimumSize: const Size(K.touch, K.touch),
                      textStyle: t.labelLarge?.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                    ),
                    child: Text(label),
                  );
              return Row(children: [
                Semantics(
                  button: true,
                  label: 'Kestrel home',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => public.goHome(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: K.s2),
                      child: PublicLogo(prototypeTag: wide),
                    ),
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: K.s5),
                  link('How it works', () => anchor(HomeAnchor.howItWorks)),
                  link('Your rights', () => anchor(HomeAnchor.rights)),
                  link('Help', public.goHelp, selected: helpSelected),
                ],
                const Spacer(),
                if (roomForSignIn) link('Sign in', () => public.signIn(), selected: false),
                if (wide) ...[
                  const SizedBox(width: K.s2),
                  FilledButton(
                    onPressed: () => anchor(HomeAnchor.booking),
                    style: FilledButton.styleFrom(
                      backgroundColor: K.textPrimary,
                      foregroundColor: K.base,
                      minimumSize: const Size(K.touch, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Manage booking'),
                  ),
                ] else
                  IconButton(
                    tooltip: 'Menu',
                    icon: const Icon(Icons.menu),
                    onPressed: () => _menu(context, anchor),
                  ),
              ]);
            }),
          ),
        ),
      ),
    );
  }

  /// The width the full bar needs: logo with its tag, the three links,
  /// "Sign in" and "Manage booking", measured at the current text size.
  static double _textWidth(BuildContext context, String s, TextStyle? style) => (TextPainter(
        text: TextSpan(text: s, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout())
          .width;

  static double _logoWidth(BuildContext context, {required bool tag}) {
    final t = Theme.of(context).textTheme;
    return 34 + K.s3 + _textWidth(context, 'Kestrel', t.titleLarge?.copyWith(fontWeight: FontWeight.w700)) +
        (tag ? K.s2 + _textWidth(context, 'PROTOTYPE', K.mono(fontSize: 10, letterSpacing: 1)) + 14 : 0);
  }

  static double _textButton(BuildContext context, String s) =>
      math.max(K.touch, _textWidth(context, s, Theme.of(context).textTheme.labelLarge) + 24);

  static double _fullBarWidth(BuildContext context) {
    final links = _textButton(context, 'How it works') + _textButton(context, 'Your rights') + _textButton(context, 'Help');
    final actions = _textButton(context, 'Sign in') + K.s2 +
        _textWidth(context, 'Manage booking', Theme.of(context).textTheme.labelLarge) + 48;
    return _logoWidth(context, tag: true) + K.s5 + links + K.s5 + actions;
  }

  /// Logo, "Sign in" and the menu button.
  static double _compactBarWidth(BuildContext context) =>
      _logoWidth(context, tag: false) + K.s4 + _textButton(context, 'Sign in') + K.touch;

  void _menu(BuildContext context, void Function(HomeAnchor) anchor) {
    final public = PublicScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.surface,
      showDragHandle: true,
      builder: (sheet) {
        Widget item(String label, IconData icon, VoidCallback onTap) => ListTile(
              leading: Icon(icon, color: K.textSecondary),
              title: Text(label),
              minTileHeight: K.touch,
              onTap: () {
                Navigator.of(sheet).pop();
                onTap();
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            item('Sign in', Icons.login, () => public.signIn()),
            item('Manage booking', Icons.confirmation_number_outlined, () => anchor(HomeAnchor.booking)),
            item('How it works', Icons.route_outlined, () => anchor(HomeAnchor.howItWorks)),
            item('Your rights', Icons.gavel_outlined, () => anchor(HomeAnchor.rights)),
            item('Help', Icons.help_outline, public.goHelp),
            item('Disruption desk staff', Icons.badge_outlined, () => public.signIn(SignInMode.staff)),
          ]),
        );
      },
    );
  }
}

/// Bottom of every public page: the disclaimer and the remaining links.
class PublicFooter extends StatelessWidget {
  const PublicFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final public = PublicScope.read(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: K.textSecondary);
    final links = Wrap(spacing: K.s2, children: [
      TextButton(
        onPressed: public.goHelp,
        style: TextButton.styleFrom(foregroundColor: K.textSecondary, minimumSize: const Size(K.touch, K.touch)),
        child: const Text('Help'),
      ),
      TextButton(
        onPressed: () => public.signIn(SignInMode.staff),
        style: TextButton.styleFrom(foregroundColor: K.textSecondary, minimumSize: const Size(K.touch, K.touch)),
        child: const Text('Staff sign-in'),
      ),
    ]);
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: K.hairline))),
      padding: const EdgeInsets.symmetric(vertical: K.s5),
      child: PublicSection(
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 760
              ? Row(children: [Expanded(child: Text('Kestrel · $disclaimer', style: small)), links])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  links,
                  const SizedBox(height: K.s2),
                  Text('Kestrel · $disclaimer', style: small),
                ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Frequently asked questions
// ---------------------------------------------------------------------------

enum FaqTopic { rebooking, vouchers, rights, accounts }

class Faq {
  const Faq(this.question, this.answer, this.topic);
  final String question, answer;
  final FaqTopic topic;
}

/// Answers describe what the system does; they never promise more than the
/// rules engine or the stored procedure deliver.
const faqs = [
  Faq('Can I get a refund instead of a new flight?',
      'Yes. If Kenya Airways cancels your flight you may take a refund for the unused part of your ticket '
          'instead of rebooking. Ask the assistant and it will cite the clause.',
      FaqTopic.rights),
  Faq('Will I pay to change to another flight?',
      'No. Kestrel only offers flights on the same route and in the same cabin as your booking, with no fare '
          'difference.',
      FaqTopic.rebooking),
  Faq('How do I use my meal or hotel voucher?',
      'Show the voucher code at the airport desk, restaurant or hotel. Codes appear under Vouchers as soon as '
          'you are rebooked, each with what it covers and until when.',
      FaqTopic.vouchers),
  Faq('What if I want a different destination?',
      'The assistant can only rebook you on the same route. For a different destination, talk to a person: '
          'the disruption desk can look at other options with you.',
      FaqTopic.rebooking),
  Faq('My voucher code doesn\'t scan. What now?',
      'Read the code out to the staff member; it is printed on the voucher. If it still is not accepted, talk '
          'to a person and the desk will check it.',
      FaqTopic.vouchers),
  Faq('How is my seat protected from double booking?',
      'Confirming claims the seat in one step on the server, so two passengers can never be given the same '
          'seat. If someone confirms first, you are shown fresh options and nothing is charged.',
      FaqTopic.rebooking),
  Faq('What am I entitled to while I wait?',
      'Meals, a hotel night with transfers when your new flight is the next day, and in some cases '
          'compensation. Fixed rules work it out from your route, the cause and your wait, and every amount '
          'shows its basis.',
      FaqTopic.rights),
  Faq('Is the assistant a real person?',
      'No. It is an AI assistant that can rebook you, explain your entitlements and cite the conditions of '
          'carriage. Whenever you ask, it hands over to a person at the disruption desk, who can see your booking '
          'and your last question.',
      FaqTopic.rights),
  Faq('Do I need an account?',
      'No. Your booking reference and surname are enough. Signing in with Google or an emailed code lets you '
          'come back without typing them.',
      FaqTopic.accounts),
];

/// An accordion of questions. Each row is a button that announces whether
/// it is expanded; answers are plain text under the question.
class FaqList extends StatefulWidget {
  const FaqList({super.key, required this.items, this.initiallyOpen = 0});
  final List<Faq> items;

  /// Index of the question shown open at first, or null for none.
  final int? initiallyOpen;

  @override
  State<FaqList> createState() => _FaqListState();
}

class _FaqListState extends State<FaqList> {
  late final _open = <String>{
    if (widget.initiallyOpen != null && widget.items.length > widget.initiallyOpen!)
      widget.items[widget.initiallyOpen!].question,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(children: [
      const Divider(height: 1),
      for (final f in widget.items) ...[
        Semantics(
          button: true,
          expanded: _open.contains(f.question),
          child: InkWell(
            onTap: () => setState(() => _open.contains(f.question) ? _open.remove(f.question) : _open.add(f.question)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: K.s1, vertical: K.s3),
                child: Row(children: [
                  Expanded(child: Text(f.question, style: t.titleMedium)),
                  const SizedBox(width: K.s3),
                  ExcludeSemantics(
                    child: Icon(_open.contains(f.question) ? Icons.remove : Icons.add, size: 18, color: K.textSecondary),
                  ),
                ]),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _open.contains(f.question)
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(K.s1, 0, K.s5, K.s4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(f.answer, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        const Divider(height: 1),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Booking reference + surname (FR-01), used on Home and on the sign-in page
// ---------------------------------------------------------------------------

String? validatePnr(String? v) {
  final s = (v ?? '').trim();
  if (s.isEmpty) return 'Enter your 6-character booking reference.';
  if (!RegExp(r'^[A-Za-z0-9]{6}$').hasMatch(s)) {
    return 'A booking reference is 6 letters and numbers, e.g. A27Z99.';
  }
  return null;
}

String? validateSurname(String? v) => (v ?? '').trim().isEmpty ? 'Enter the surname on the booking.' : null;

class UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

/// The guest sign-in: booking reference and surname exchanged for a
/// 15-minute session token. [horizontal] lays the fields out in a row (the
/// Home page on a laptop).
class GuestBookingForm extends StatefulWidget {
  const GuestBookingForm({super.key, this.horizontal = false, this.pnrFocus, this.autofocus = false});
  final bool horizontal;
  final FocusNode? pnrFocus;
  final bool autofocus;

  static const submitKey = Key('guest-submit');

  @override
  State<GuestBookingForm> createState() => _GuestBookingFormState();
}

class _GuestBookingFormState extends State<GuestBookingForm> {
  final _form = GlobalKey<FormState>();
  final _pnr = TextEditingController();
  final _surname = TextEditingController();
  final _surnameFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pnr.dispose();
    _surname.dispose();
    _surnameFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SessionScope.read(context).signIn(_pnr.text, _surname.text);
      // SessionGate swaps the public site for the passenger app.
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pnr = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Booking reference'),
      const SizedBox(height: K.s2),
      TextFormField(
        controller: _pnr,
        focusNode: widget.pnrFocus,
        enabled: !_busy,
        autofocus: widget.autofocus,
        maxLength: 6,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.next,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), UpperCase()],
        style: K.mono(fontSize: 16, letterSpacing: 2, color: K.textPrimary),
        decoration: const InputDecoration(hintText: 'A27Z99', counterText: ''),
        validator: validatePnr,
        onFieldSubmitted: (_) => _surnameFocus.requestFocus(),
      ),
    ]);
    final surname = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Surname'),
      const SizedBox(height: K.s2),
      TextFormField(
        controller: _surname,
        focusNode: _surnameFocus,
        enabled: !_busy,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.familyName],
        decoration: const InputDecoration(hintText: 'As on your ticket'),
        validator: validateSurname,
        onFieldSubmitted: (_) => _submit(),
      ),
    ]);
    final button = PrimaryButton(
      key: GuestBookingForm.submitKey,
      label: 'Find my booking',
      busy: _busy,
      onPressed: _submit,
      height: widget.horizontal ? 54 : 56,
      expand: !widget.horizontal,
    );
    return AutofillGroup(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.horizontal)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: pnr),
              const SizedBox(width: K.s3),
              Expanded(child: surname),
              const SizedBox(width: K.s3),
              Padding(padding: const EdgeInsets.only(top: 26), child: button),
            ])
          else ...[
            pnr,
            const SizedBox(height: K.s4),
            surname,
            const SizedBox(height: K.s5),
            button,
          ],
          if (_error != null) ...[
            const SizedBox(height: K.s3),
            ErrorNotice(message: _error!),
          ],
        ]),
      ),
    );
  }
}
