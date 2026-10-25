import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../state/chat.dart';
import '../state/public.dart';
import '../state/session.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/shell.dart';
import 'alternatives_screen.dart';
import 'chat_screen.dart';
import 'handoff_screen.dart';
import 'trip_screen.dart';
import 'vouchers_screen.dart';

/// The passenger app's layout: a sidebar and top bar in a laptop browser, a
/// tab bar on a phone, around one of five sections (My trip, Assistant,
/// Flights, Vouchers, Help).
class PassengerShell extends StatefulWidget {
  const PassengerShell({super.key});

  @override
  State<PassengerShell> createState() => _PassengerShellState();
}

const _phoneLabels = {
  Section.trip: 'Trip',
  Section.assistant: 'Assistant',
  Section.flights: 'Flights',
  Section.vouchers: 'Vouchers',
  Section.help: 'Help',
};

class _PassengerShellState extends State<PassengerShell> {
  late final ChatController _chat;
  late final TripStore _trip;
  late final ShellController _shell;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _shell = ShellScope.read(context)..resetForNewSession();
    PublicScope.read(context).resetForSignedIn();
    final session = SessionScope.read(context);
    _trip = session.trip!..addListener(_onTrip);
    _chat = ChatController(
      session,
      trip: _trip,
      onError: (e) => mounted ? handleApiError(context, e) : null,
    );
    _shell.addListener(_onSection);
    _onTrip(); // the first load may already have failed
  }

  @override
  void dispose() {
    _shell.removeListener(_onSection);
    _trip.removeListener(_onTrip);
    _chat.dispose();
    super.dispose();
  }

  /// Switching section shows the stored trip at once and, if it is over a
  /// minute old, fetches a fresh one behind it.
  void _onSection() => _trip.refreshIfStale();

  /// A refresh answered 401: the 15-minute session has ended.
  void _onTrip() {
    final failure = _trip.failure;
    if (_expired || failure is! ApiException || !failure.sessionExpired) return;
    _expired = true;
    // Not while the store is still telling its listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) handleApiError(context, failure);
    });
  }

  /// A question from outside the Assistant: open the Assistant and send it.
  /// [intent] comes only from a quick-reply chip.
  void _ask(String text, {String? intent}) {
    ShellScope.read(context).go(Section.assistant);
    _chat.send(text, intent: intent);
  }

  void _person() {
    final q = _chat.lastQuestion;
    askForPerson(context,
        summary: q.isEmpty
            ? 'Passenger asked to speak to a person.'
            : 'Passenger asked for a person. Last question: $q');
  }

  void _signOut() => SessionScope.read(context).signOut();

  /// Null (no menu item) unless the account is linked to this booking.
  VoidCallback? get _unlink => SessionScope.read(context).linkedAccount == null
      ? null
      : () async {
          final public = PublicScope.read(context);
          try {
            await SessionScope.read(context).unlinkBooking();
            public.notice = 'Booking unlinked. Your account will ask for a booking next time you sign in.';
          } catch (e) {
            if (mounted) handleApiError(context, e);
          }
        };

  Widget _section(Section s) => switch (s) {
        Section.trip => TripScreen(onAsk: _ask),
        Section.assistant => ChatScreen(chat: _chat, onPerson: _person),
        Section.flights => const AlternativesScreen(),
        Section.vouchers => const VouchersScreen(),
        Section.help => HandoffScreen(onPerson: _person),
      };

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final booking = SessionScope.of(context).booking!;
    // The trip is above everything in the layout, so the sidebar's "Need a
    // person?" and the top bar can refresh it too.
    return TripScope(store: _trip, child: LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= Breakpoints.wide;
      // Each section has its own navigator, so pages opened from it (confirm,
      // rebooked) stay inside the layout. Switching section starts afresh.
      final body = _SectionNavigator(key: ValueKey(shell.section), child: _section(shell.section));
      if (wide) {
        return Scaffold(
          body: SafeArea(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Sidebar(onPerson: _person, onSignOut: _signOut),
              Expanded(
                child: Column(children: [
                  TopBar(
                    booking: booking,
                    showAsk: shell.section != Section.assistant,
                    onAsk: _ask,
                    onSignOut: _signOut,
                    onUnlink: _unlink,
                  ),
                  Expanded(child: body),
                ]),
              ),
            ]),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          titleSpacing: K.s4,
          title: const Row(children: [
            KestrelMark(size: 30),
            SizedBox(width: K.s3),
            Text('Kestrel'),
          ]),
          actions: [
            AccountMenu(booking: booking, onSignOut: _signOut, onUnlink: _unlink),
            const SizedBox(width: K.s2),
          ],
        ),
        body: body,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.section.index,
          onDestinationSelected: (i) => shell.go(Section.values[i]),
          destinations: [
            for (final s in Section.values)
              NavigationDestination(icon: Icon(sectionIcons[s]), label: _phoneLabels[s]!),
          ],
        ),
      );
    }));
  }
}

/// A navigator for one section's pages, inside the sidebar/top bar (laptop)
/// or above the tab bar (phone). The system Back button pops its pages
/// before it would leave the app.
class _SectionNavigator extends StatefulWidget {
  const _SectionNavigator({super.key, required this.child});
  final Widget child;

  @override
  State<_SectionNavigator> createState() => _SectionNavigatorState();
}

class _SectionNavigatorState extends State<_SectionNavigator> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler<Object?>(
      onPopWithResult: (_) => _navigator.currentState?.maybePop(),
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (settings) =>
            MaterialPageRoute<void>(settings: settings, builder: (_) => widget.child),
      ),
    );
  }
}
