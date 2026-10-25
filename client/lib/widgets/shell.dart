import 'package:flutter/material.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import 'api_error.dart';
import 'common.dart';

/// The pieces of the dashboard layout: sidebar (laptop), top bar, phone tab
/// bar, and the "need a person?" panel.

const sectionIcons = {
  Section.trip: Icons.grid_view_rounded,
  Section.assistant: Icons.chat_bubble_outline_rounded,
  Section.flights: Icons.flight_takeoff,
  Section.vouchers: Icons.confirmation_number_outlined,
  Section.help: Icons.support_agent,
};

const sectionLabels = {
  Section.trip: 'My trip',
  Section.assistant: 'Assistant',
  Section.flights: 'Flights',
  Section.vouchers: 'Vouchers',
  Section.help: 'Help',
};

/// FR-05 from anywhere in the app: opens a case and shows it on Help.
Future<void> askForPerson(BuildContext context, {String? summary}) async {
  final session = SessionScope.read(context);
  final shell = ShellScope.read(context);
  final trip = TripScope.maybeRead(context);
  if (shell.requestingPerson) return;
  shell.setRequesting(true);
  try {
    final c = await session.api
        .requestPerson(summary ?? 'Passenger asked to speak to a person.');
    shell.showCase(c);
    trip?.refreshQuietly(); // the case appears in the trip's cases and suggestions
  } catch (e) {
    if (!context.mounted) return;
    final msg = handleApiError(context, e);
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  } finally {
    shell.setRequesting(false);
  }
}

/// Laptop navigation: brand, the five sections, the "need a person?" panel
/// and sign-out.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.onPerson, required this.onSignOut});
  final VoidCallback onPerson;
  final VoidCallback onSignOut;

  static const width = 264.0;

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final t = Theme.of(context).textTheme;
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: K.void_,
        border: Border(right: BorderSide(color: K.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(K.s5, 28, K.s5, 0),
                  child: Align(alignment: Alignment.centerLeft, child: BrandLockup(markSize: 40)),
                ),
                const SizedBox(height: 40),
                Semantics(
                  container: true,
                  label: 'Sections',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: K.s4),
                    child: Column(children: [
                      for (final s in Section.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: K.s1),
                          child: NavItem(
                            icon: sectionIcons[s]!,
                            label: sectionLabels[s]!,
                            selected: shell.section == s,
                            onTap: () => shell.go(s),
                          ),
                        ),
                    ]),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(K.s4),
                  child: NeedPersonCard(onPressed: onPerson, busy: shell.requestingPerson),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(K.s3, 0, K.s4, K.s4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TextButton.icon(
                      onPressed: onSignOut,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Sign out'),
                      style: TextButton.styleFrom(
                        foregroundColor: K.textSecondary,
                        minimumSize: const Size(K.touch, K.touch),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: K.s3),
                      child: Text(
                        'Your session ends 15 minutes after sign-in. Nothing is saved in this browser.',
                        style: t.bodySmall?.copyWith(color: K.textSecondary, fontSize: 12),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: K.s3),
                      child: Divider(height: K.s5),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: K.s3),
                      child: Text(disclaimer, style: t.bodySmall?.copyWith(color: K.textSecondary, fontSize: 12)),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// One sidebar entry. The selected one gets the crimson icon tile.
class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A number shown on the right (the staff desk's case counts).
  final int? count;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: count == null ? label : '$label, $count',
      excludeSemantics: true,
      child: Material(
        color: selected ? K.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: K.s2),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: selected
                      ? BoxDecoration(
                          gradient: K.primaryGradient,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: const [BoxShadow(color: Color(0x55FF2E55), blurRadius: 12)],
                        )
                      : null,
                  child: Icon(icon, size: 20, color: selected ? Colors.white : K.textSecondary),
                ),
                const SizedBox(width: K.s3),
                Expanded(
                  child: Text(
                    label,
                    style: t.titleMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? K.textPrimary : K.textSecondary,
                    ),
                  ),
                ),
                if (count != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: selected ? K.crimsonSoft : K.elevated,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('$count',
                        style: K.label(context).copyWith(color: selected ? K.glow : K.textSecondary)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The crimson panel at the foot of the sidebar: a person is always one
/// click away.
class NeedPersonCard extends StatelessWidget {
  const NeedPersonCard({super.key, required this.onPressed, this.busy = false});
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: K.primaryGradient),
        child: Stack(children: [
          const Waves(),
          Padding(
            padding: const EdgeInsets.all(K.s5),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.support_agent, color: Colors.white),
              const SizedBox(height: K.s3),
              Text('Need a person?', style: t.titleMedium?.copyWith(color: Colors.white)),
              const SizedBox(height: K.s1),
              Text(
                'Our disruption desk can take over. They see your booking and your last question.',
                style: t.bodySmall?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: K.s4),
              Semantics(
                button: true,
                enabled: !busy,
                label: busy ? 'Talk to a person, working' : 'Talk to a person',
                excludeSemantics: true,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: busy ? null : onPressed,
                    child: SizedBox(
                      height: K.touch,
                      width: double.infinity,
                      child: Center(
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: K.crimson600),
                              )
                            : Text('Talk to a person',
                                style: t.labelLarge?.copyWith(color: K.crimson600)),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Laptop top bar: "Ask Kestrel" (sends straight to the assistant), the
/// booking reference and the passenger.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.booking,
    required this.showAsk,
    required this.onAsk,
    required this.onSignOut,
    this.onUnlink,
  });
  final Booking booking;
  final bool showAsk;
  final ValueChanged<String> onAsk;
  final VoidCallback onSignOut;
  final VoidCallback? onUnlink;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: K.hairline))),
      child: Row(children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: showAsk
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: AskField(onAsk: onAsk),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        const SizedBox(width: K.s4),
        PnrChip(booking.pnr),
        const SizedBox(width: K.s3),
        AccountMenu(booking: booking, onSignOut: onSignOut, onUnlink: onUnlink, showName: true),
      ]),
    );
  }
}

/// A search-style field whose question goes to the assistant.
class AskField extends StatefulWidget {
  const AskField({super.key, required this.onAsk});
  final ValueChanged<String> onAsk;

  @override
  State<AskField> createState() => _AskFieldState();
}

class _AskFieldState extends State<AskField> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    _c.clear();
    widget.onAsk(text);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: 'Ask Kestrel about your trip…',
        prefixIcon: const Icon(Icons.search, color: K.textSecondary),
        suffixIcon: IconButton(
          tooltip: 'Ask',
          icon: const Icon(Icons.arrow_forward, color: K.glow),
          onPressed: _submit,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: 14),
      ),
    );
  }
}

class PnrChip extends StatelessWidget {
  const PnrChip(this.pnr, {super.key});
  final String pnr;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Booking reference $pnr',
        excludeSemantics: true,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: K.s3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: K.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: K.hairline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.confirmation_number_outlined, size: 16, color: K.glow),
            const SizedBox(width: 6),
            Text(pnr, style: K.dataMd(context).copyWith(fontSize: 14, letterSpacing: 1.2)),
          ]),
        ),
      );
}

/// The signed-in passenger, with sign-out in its menu.
class AccountMenu extends StatelessWidget {
  const AccountMenu(
      {super.key, required this.booking, required this.onSignOut, this.onUnlink, this.showName = false});
  final Booking booking;
  final VoidCallback onSignOut;

  /// Shown only when the signed-in account is linked to this booking.
  final VoidCallback? onUnlink;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = '${booking.firstName} ${booking.lastName}'.trim();
    return PopupMenuButton<String>(
      tooltip: 'Account',
      position: PopupMenuPosition.under,
      onSelected: (v) => v == 'unlink' ? onUnlink?.call() : onSignOut(),
      itemBuilder: (_) => [
        if (onUnlink != null) const PopupMenuItem(value: 'unlink', child: Text('Unlink this booking')),
        const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
      child: Padding(
        padding: const EdgeInsets.all(K.s1),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          InitialsAvatar(initials(booking.firstName, booking.lastName)),
          if (showName) ...[
            const SizedBox(width: K.s3),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name, style: t.titleMedium?.copyWith(fontSize: 14)),
              Text('${titleCase(booking.tier)} member',
                  style: t.bodySmall?.copyWith(color: K.amber, fontSize: 12)),
            ]),
            const SizedBox(width: K.s1),
            const Icon(Icons.expand_more, color: K.textSecondary),
          ],
        ]),
      ),
    );
  }
}
