import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../format.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/public.dart';

/// 03-LinkBooking. The account is signed in (Google or an emailed code) but
/// not yet linked to a booking. Offers the bookings under its verified email
/// address, or any other booking by reference and surname. Done once.
class LinkBookingScreen extends StatefulWidget {
  const LinkBookingScreen({super.key, required this.link});
  final AccountLink link;

  @override
  State<LinkBookingScreen> createState() => _LinkBookingScreenState();
}

class _LinkBookingScreenState extends State<LinkBookingScreen> {
  final _form = GlobalKey<FormState>();
  final _pnr = TextEditingController();
  final _surname = TextEditingController();

  /// The suggestion chosen, or null for "a different booking".
  LinkSuggestion? _chosen;
  late bool _other = widget.link.suggestions.isEmpty;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.link.suggestions.isNotEmpty) _chosen = widget.link.suggestions.first;
  }

  @override
  void dispose() {
    _pnr.dispose();
    _surname.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    if (_busy) return;
    if (_other && !(_form.currentState?.validate() ?? false)) return;
    final session = SessionScope.read(context);
    final public = PublicScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final still = await session.signInWithAccount(
        widget.link.identity,
        pnr: _other ? _pnr.text : _chosen!.pnr,
        lastName: _other ? _surname.text : null,
      );
      // Not expected once a booking is given, but never leave a dead end.
      if (still != null) public.showLinkBooking(AccountLink(widget.link.identity, still));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Back to the sign-in page as a guest, signed out of the account.
  void _skip() {
    SessionScope.read(context).auth.signOut();
    PublicScope.read(context).signIn(SignInMode.guest);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final identity = widget.link.identity;
    final provider = identity.provider == 'google' ? 'Google' : 'email';
    final suggestions = widget.link.suggestions;
    final local = identity.email.split('@').first;
    return Scaffold(
      backgroundColor: K.base,
      body: Column(children: [
        // Top bar: the logo, and who is signed in.
        Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: K.hairline))),
          child: SafeArea(
            bottom: false,
            child: PublicSection(
              child: SizedBox(
                height: 68,
                child: Row(children: [
                  const PublicLogo(prototypeTag: false),
                  const Spacer(),
                  // The address is also in the line above the heading; the
                  // bar repeats it only where there is room.
                  ExcludeSemantics(child: InitialsAvatar(initials(local, ''), size: 32)),
                  if (MediaQuery.sizeOf(context).width >= 720) ...[
                    const SizedBox(width: K.s2),
                    Flexible(
                      child: ExcludeSemantics(
                        child: Text(identity.email,
                            overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(color: K.textSecondary)),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: 56),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: IconChip(Icons.link, background: K.elevated, size: 56)),
                  const SizedBox(height: K.s3),
                  Text('Signed in with $provider · ${identity.email}',
                      textAlign: TextAlign.center, style: K.mono(fontSize: 12.5, letterSpacing: 0.4, color: K.teal)),
                  const SizedBox(height: K.s2),
                  Semantics(
                    header: true,
                    child: Text('Link your booking',
                        textAlign: TextAlign.center,
                        style: t.headlineSmall?.copyWith(fontSize: 30, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: K.s3),
                  Text(
                    suggestions.isNotEmpty
                        ? 'We found ${suggestions.length == 1 ? 'a booking' : 'bookings'} that match your email. '
                            'Confirm which is yours, or add another one with its reference and surname. '
                            'You only do this once.'
                        : 'Add your booking with its reference and the surname on the ticket. You only do this once.',
                    textAlign: TextAlign.center,
                    style: t.bodyLarge?.copyWith(color: K.textSecondary),
                  ),
                  const SizedBox(height: K.s5),
                  Container(
                    padding: const EdgeInsets.all(K.s5),
                    decoration: BoxDecoration(
                      color: K.surface,
                      borderRadius: BorderRadius.circular(K.radiusLg),
                      border: Border.all(color: K.hairline),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (suggestions.isNotEmpty) ...[
                        Text('MATCHED TO YOUR EMAIL', style: K.mono(fontSize: 11, letterSpacing: 1.4, color: K.textSecondary)),
                        const SizedBox(height: K.s3),
                        for (final s in suggestions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: K.s2),
                            child: _SuggestionTile(
                              suggestion: s,
                              selected: !_other && _chosen == s,
                              onTap: _busy ? null : () => setState(() {
                                _chosen = s;
                                _other = false;
                              }),
                            ),
                          ),
                        const Divider(height: K.s4),
                      ],
                      if (!_other)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _busy ? null : () => setState(() => _other = true),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add a different booking'),
                            style: TextButton.styleFrom(
                              foregroundColor: K.glow,
                              minimumSize: const Size(K.touch, K.touch),
                              padding: EdgeInsets.zero,
                            ),
                          ),
                        )
                      else
                        Form(
                          key: _form,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            const SectionLabel('Booking reference'),
                            const SizedBox(height: K.s2),
                            TextFormField(
                              controller: _pnr,
                              enabled: !_busy,
                              autofocus: suggestions.isNotEmpty,
                              maxLength: 6,
                              textCapitalization: TextCapitalization.characters,
                              textInputAction: TextInputAction.next,
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')), UpperCase()],
                              style: K.mono(fontSize: 16, letterSpacing: 2, color: K.textPrimary),
                              decoration: const InputDecoration(hintText: 'A27Z99', counterText: ''),
                              validator: validatePnr,
                            ),
                            const SizedBox(height: K.s4),
                            const SectionLabel('Surname'),
                            const SizedBox(height: K.s2),
                            TextFormField(
                              controller: _surname,
                              enabled: !_busy,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.familyName],
                              decoration: const InputDecoration(hintText: 'As on your ticket'),
                              validator: validateSurname,
                              onFieldSubmitted: (_) => _link(),
                            ),
                            if (suggestions.isNotEmpty)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: _busy ? null : () => setState(() => _other = false),
                                  style: TextButton.styleFrom(
                                    foregroundColor: K.textSecondary,
                                    minimumSize: const Size(K.touch, K.touch),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: const Text('Use the matched booking instead'),
                                ),
                              ),
                          ]),
                        ),
                    ]),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: K.s4),
                    ErrorNotice(message: _error!),
                  ],
                  const SizedBox(height: K.s5),
                  PrimaryButton(label: 'Link and continue', busy: _busy, onPressed: _link),
                  const SizedBox(height: K.s3),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : _skip,
                      style: TextButton.styleFrom(foregroundColor: K.textSecondary, minimumSize: const Size(K.touch, K.touch)),
                      child: const Text('Skip for now'),
                    ),
                  ),
                  const SizedBox(height: K.s3),
                  Text(
                    'Only a booking under ${identity.email} is linked to your account. Another '
                    'booking opens for this visit only, like a guest sign-in.',
                    textAlign: TextAlign.center,
                    style: t.bodySmall?.copyWith(color: K.textSecondary),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.suggestion, required this.selected, required this.onTap});
  final LinkSuggestion suggestion;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = suggestion;
    final date = s.departureDate == null ? '' : dayLabel('${s.departureDate}T00:00');
    return Semantics(
      button: true,
      selected: selected,
      label: 'Booking ${s.pnr}, ${city(s.origin)} to ${city(s.destination)}${date.isEmpty ? '' : ', $date'}, '
          '${titleCase(s.bookingStatus)}',
      excludeSemantics: true,
      child: Material(
        color: selected ? K.tealSoft : K.inset,
        borderRadius: BorderRadius.circular(K.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(K.radius),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(K.s4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(K.radius),
              border: Border.all(color: selected ? K.teal.withAlpha(140) : K.hairline),
            ),
            child: Row(children: [
              Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: selected ? K.teal : K.textSecondary),
              const SizedBox(width: K.s3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s.pnr} · ${s.origin} → ${s.destination}',
                      style: K.mono(fontSize: 14, fontWeight: FontWeight.w600, color: K.textPrimary)),
                  if (date.isNotEmpty) Text(date, style: t.bodySmall?.copyWith(color: K.textSecondary)),
                ]),
              ),
              const SizedBox(width: K.s2),
              StatusPill(s.bookingStatus),
            ]),
          ),
        ),
      ),
    );
  }
}
