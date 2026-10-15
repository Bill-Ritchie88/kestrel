import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/session.dart';
import '../theme.dart';
import '../widgets/api_error.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import 'alternatives_screen.dart';
import 'confirm_screen.dart';
import 'handoff_screen.dart';
import 'vouchers_screen.dart';

/// M05 / M08 · Chat (UC2, UC3). Each turn goes to the agent service (:8001),
/// which calls the REST tier's tools with this passenger's token. The
/// structured results it returns (flights, rebooking, clauses, entitlements,
/// hand-off) are drawn as cards under the reply, from the same data the
/// model saw, so the screen never depends on the model's wording for facts.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _Message {
  _Message.user(this.text)
      : fromUser = true,
        events = const [],
        totalMs = null,
        error = null;
  _Message.agent(this.text, {this.events = const [], this.totalMs})
      : fromUser = false,
        error = null;
  _Message.error(String this.error)
      : fromUser = false,
        text = '',
        events = const [],
        totalMs = null;

  final bool fromUser;
  final String text;
  final List<AgentEvent> events;
  final int? totalMs;
  final String? error;
}

const _quickReplies = [
  'Find me another flight',
  'What am I entitled to?',
  'Can I get a refund instead?',
];

class _ChatScreenState extends State<ChatScreen> {
  final _messages = <_Message>[];
  final _input = TextEditingController();
  // Enter sends, Shift+Enter starts a new line - what people expect from a
  // chat box in a browser.
  late final _inputFocus = FocusNode(onKeyEvent: _onComposerKey);
  final _scroll = ScrollController();
  final _speech = SpeechToText();
  bool _busy = false;
  bool _speechReady = false;
  bool _listening = false;
  String? _lastFailed;

  @override
  void initState() {
    super.initState();
    final booking = SessionScope.read(context).booking;
    if (booking != null) _messages.add(_Message.agent(_greeting(booking)));
  }

  @override
  void dispose() {
    _speech.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// UC2 opening message, written from the booking rather than by the model:
  /// it is instant and states only facts the REST tier returned.
  static String _greeting(Booking b) {
    final f = b.original;
    final name = b.firstName.isNotEmpty ? b.firstName : b.lastName;
    if (b.isRebooked && b.current != null) {
      final c = b.current!;
      return 'Hello $name. You\'re booked on ${c.number} to ${city(f.destination)}, '
          'departing ${dayLabel(c.departureLocal)} at ${hhmm(c.departureLocal)} local time, '
          'seat ${b.seat ?? '-'}. I can explain your vouchers and rights, '
          'or put you through to a person.';
    }
    if (b.isDisrupted) {
      final reason = reasonText[f.disruptionReason];
      return 'Hello $name, I\'m sorry. Your flight ${f.number} from ${city(f.origin)} '
          'to ${city(f.destination)} on ${dayLabel(f.departureLocal)} at '
          '${hhmm(f.departureLocal)} has been cancelled'
          '${reason == null ? '' : ' because of $reason'}. '
          'I can find you another flight, tell you what you\'re entitled to, '
          'or put you through to a person.';
    }
    return 'Hello $name. Your booking ${b.pnr} is ${titleCase(b.status)}. '
        'Ask me anything about your trip.';
  }

  List<Map<String, String>> _history() => [
        for (final m in _messages)
          if (m.error == null && m.text.isNotEmpty)
            {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
      ];

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final reduce = MediaQuery.of(context).disableAnimations;
      final end = _scroll.position.maxScrollExtent;
      reduce
          ? _scroll.jumpTo(end)
          : _scroll.animateTo(end,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    // Read the session before any await, so no BuildContext crosses an
    // async gap.
    final session = SessionScope.read(context);
    if (_listening) await _speech.stop();
    if (!mounted) return;
    final history = _history();
    setState(() {
      _messages.add(_Message.user(text));
      _busy = true;
      _listening = false;
      _lastFailed = null;
      _input.clear();
    });
    _scrollToEnd();
    try {
      final reply = await session.api.chat(text, history.length > 20
          ? history.sublist(history.length - 20)
          : history);
      if (!mounted) return;
      setState(() => _messages.add(
          _Message.agent(reply.reply, events: reply.events, totalMs: reply.totalMs)));
      // A rebooking changes the booking shown everywhere else.
      if (reply.events.any((e) => e.type == 'rebooked')) await session.refresh();
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      if (msg != null) {
        setState(() {
          _messages.add(_Message.error(msg));
          _lastFailed = text;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToEnd();
    }
  }

  Future<void> _toggleMic() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      try {
        _speechReady = await _speech.initialize(
          onStatus: (s) {
            if ((s == 'done' || s == 'notListening') && mounted) {
              setState(() => _listening = false);
            }
          },
          onError: (_) {
            if (mounted) setState(() => _listening = false);
          },
        );
      } catch (_) {
        _speechReady = false;
      }
      if (!_speechReady) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Voice input isn\'t available here. You can type your question.')));
        return;
      }
    }
    setState(() => _listening = true);
    await _speech.listen(onResult: _onSpeech);
  }

  void _onSpeech(SpeechRecognitionResult r) {
    _input.text = r.recognizedWords;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Future<void> _talkToPerson() async {
    final session = SessionScope.read(context);
    final lastQuestion = _messages.lastWhere((m) => m.fromUser,
        orElse: () => _Message.user('')).text;
    setState(() => _busy = true);
    try {
      final c = await session.api.requestPerson(lastQuestion.isEmpty
          ? 'Passenger asked to speak to a person from the chat screen.'
          : 'Passenger asked for a person. Last question: $lastQuestion');
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => HandoffScreen(initial: c)));
    } catch (e) {
      if (!mounted) return;
      final msg = handleApiError(context, e);
      if (msg != null) setState(() => _messages.add(_Message.error(msg)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  void _signOut() {
    SessionScope.read(context).signOut();
  }

  // -- Event cards ------------------------------------------------------------

  List<Widget> _eventCards(AgentEvent e) {
    final d = e.data;
    switch (e.type) {
      case 'alternatives':
        final flights = asList(d['alternatives']).map(Flight.new).toList();
        if (flights.isEmpty) return const [];
        return [
          for (final (i, f) in flights.take(3).indexed)
            FlightOptionCard(
              flight: f,
              recommended: i == 0,
              onSelect: () => _open(ConfirmScreen(flight: f)),
            ),
          if (flights.length > 3)
            _LinkButton(
              label: 'See all ${flights.length} flights',
              onPressed: () => _open(const AlternativesScreen()),
            ),
        ];
      case 'rebooked':
        final booking = asMap(d['booking']);
        final vouchers = asList(asMap(d['entitlements'])['vouchers'])
            .map(Voucher.new)
            .where((v) => v.isLive)
            .toList();
        return [
          if (booking.isNotEmpty) BookingCard(booking: Booking(booking)),
          for (final v in vouchers) VoucherCard(voucher: v),
        ];
      case 'policy':
        final hits = asList(d['hits']);
        if (d['in_scope'] == true && hits.isNotEmpty) return [CitationList(hits: hits)];
        final c = asMap(d['case']);
        return [if (c.isNotEmpty) HandoffCard(handoff: HandoffCase(c))];
      case 'entitlements':
        final decision = EntitlementDecision(asMap(d['decision']));
        return [
          EntitlementsCard(decision: decision),
          _LinkButton(
            label: 'Open my vouchers',
            onPressed: () => _open(const VouchersScreen()),
          ),
        ];
      case 'handoff':
        return [HandoffCard(handoff: HandoffCase(d))];
      case 'error':
        return [ErrorNotice(message: (d['detail'] ?? 'That action failed.').toString())];
      default:
        return const [];
    }
  }

  Widget _messageView(_Message m) {
    if (m.error != null) {
      return ErrorNotice(
        message: m.error!,
        onRetry: (_lastFailed != null && !_busy && identical(m, _messages.last))
            ? () {
                final text = _lastFailed!;
                setState(() => _messages
                  ..remove(m)
                  ..removeLast()); // the failed user message is re-sent below
                _send(text);
              }
            : null,
      );
    }
    final cards = [for (final e in m.events) ..._eventCards(e)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.text.isNotEmpty) ChatBubble(text: m.text, fromUser: m.fromUser),
        if (m.totalMs != null)
          Padding(
            padding: const EdgeInsets.only(left: 36, top: K.s1),
            child: Text('Answered in ${(m.totalMs! / 1000).toStringAsFixed(1)} s',
                style: K.label(context)),
          ),
        for (final c in cards)
          Padding(padding: const EdgeInsets.only(top: K.s3, left: 36), child: c),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final booking = SessionScope.of(context).booking;
    return LayoutBuilder(builder: (context, c) {
      // In a desktop browser the booking and the actions sit in a side panel
      // next to the conversation; on a phone they move into the app bar and
      // the top of the conversation.
      final wide = c.maxWidth >= Breakpoints.wide;
      final conversation = _conversation(booking, showBooking: !wide, autofocus: wide);
      return Scaffold(
        appBar: AppBar(
          titleSpacing: K.s4,
          title: const Row(children: [
            KestrelMark(size: 32),
            SizedBox(width: K.s3),
            Text('Kestrel'),
          ]),
          actions: wide
              ? null
              : [
                  IconButton(
                    tooltip: 'Other flights',
                    icon: const Icon(Icons.flight_takeoff),
                    onPressed: () => _open(const AlternativesScreen()),
                  ),
                  IconButton(
                    tooltip: 'Vouchers',
                    icon: const Icon(Icons.card_giftcard),
                    onPressed: () => _open(const VouchersScreen()),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) {
                      if (v == 'person') {
                        _talkToPerson();
                      } else {
                        _signOut();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'person', child: Text('Talk to a person')),
                      PopupMenuItem(value: 'signout', child: Text('Sign out')),
                    ],
                  ),
                ],
        ),
        body: SafeArea(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: 380,
                    child: _SidePanel(
                      booking: booking,
                      busy: _busy,
                      onFlights: () => _open(const AlternativesScreen()),
                      onVouchers: () => _open(const VouchersScreen()),
                      onPerson: _talkToPerson,
                      onSignOut: _signOut,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: K.hairline),
                  Expanded(child: conversation),
                ])
              : conversation,
        ),
      );
    });
  }

  Widget _conversation(Booking? booking, {required bool showBooking, required bool autofocus}) {
    return LayoutBuilder(builder: (context, c) {
      final padding = pagePadding(c.maxWidth, maxWidth: Breakpoints.chat, top: K.s2);
      return Column(children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: padding,
            children: [
              if (showBooking && booking != null) BookingCard(booking: booking),
              for (final (i, m) in _messages.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 && !showBooking ? 0 : K.s4),
                  child: _messageView(m),
                ),
              if (_busy)
                const Padding(padding: EdgeInsets.only(top: K.s4), child: ThinkingBubble()),
            ],
          ),
        ),
        if (!_busy && _messages.length <= 1)
          SizedBox(
            height: K.touch + K.s2,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: padding.left),
              children: [
                for (final q in _quickReplies)
                  Padding(
                    padding: const EdgeInsets.only(right: K.s2),
                    child: ActionChip(
                      label: Text(q),
                      onPressed: () => _send(q),
                      backgroundColor: K.surface,
                      side: const BorderSide(color: K.crimsonStroke),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.support_agent, size: 18),
                  label: const Text('Talk to a person'),
                  onPressed: _talkToPerson,
                  backgroundColor: K.surface,
                  side: const BorderSide(color: K.hairline),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ],
            ),
          ),
        DecoratedBox(
          decoration: const BoxDecoration(
            color: K.base,
            border: Border(top: BorderSide(color: K.hairline)),
          ),
          child: CentredBar(
            maxWidth: Breakpoints.chat + 2 * K.s4,
            child: _Composer(
              controller: _input,
              focusNode: _inputFocus,
              busy: _busy,
              listening: _listening,
              autofocus: autofocus,
              onSend: _send,
              onMic: _toggleMic,
            ),
          ),
        ),
      ]);
    });
  }
}

/// Desktop side panel: the passenger's booking and every action one click
/// away, so the conversation column can stay at a readable width.
class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.booking,
    required this.busy,
    required this.onFlights,
    required this.onVouchers,
    required this.onPerson,
    required this.onSignOut,
  });
  final Booking? booking;
  final bool busy;
  final VoidCallback onFlights, onVouchers, onPerson, onSignOut;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ColoredBox(
      color: K.void_,
      child: ListView(
        padding: const EdgeInsets.all(K.s5),
        children: [
          const SectionLabel('Your booking'),
          const SizedBox(height: K.s3),
          if (booking != null) BookingCard(booking: booking!),
          const SizedBox(height: K.s5),
          const SectionLabel('What you can do'),
          const SizedBox(height: K.s3),
          SecondaryButton(
            label: 'See other flights',
            icon: Icons.flight_takeoff,
            onPressed: onFlights,
          ),
          const SizedBox(height: K.s3),
          SecondaryButton(
            label: 'Vouchers & entitlements',
            icon: Icons.card_giftcard,
            onPressed: onVouchers,
          ),
          const SizedBox(height: K.s3),
          SecondaryButton(
            label: 'Talk to a person',
            icon: Icons.support_agent,
            onPressed: busy ? null : onPerson,
          ),
          const SizedBox(height: K.s5),
          Row(children: [
            const Icon(Icons.lock_outline, size: 16, color: K.textSecondary),
            const SizedBox(width: K.s2),
            Expanded(
              child: Text(
                'Your session ends 15 minutes after sign-in. Nothing is saved in this browser.',
                style: t.bodySmall?.copyWith(color: K.textSecondary),
              ),
            ),
          ]),
          const SizedBox(height: K.s2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out'),
              style: TextButton.styleFrom(
                foregroundColor: K.textSecondary,
                minimumSize: const Size(K.touch, K.touch),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: Text(label),
          style: TextButton.styleFrom(
              foregroundColor: K.glow, minimumSize: const Size(K.touch, K.touch)),
        ),
      );
}

/// Input bar: text field, dictation and send. Dictation fills the field so
/// the passenger can check the words before sending.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.listening,
    required this.onSend,
    required this.onMic,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy, listening, autofocus;
  final Future<void> Function([String?]) onSend;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(K.s3, K.s2, K.s3, K.s3),
      child: Row(children: [
        IconButton(
          tooltip: listening ? 'Stop dictation' : 'Speak your question',
          isSelected: listening,
          constraints: const BoxConstraints(minWidth: K.touch, minHeight: K.touch),
          icon: Icon(listening ? Icons.mic : Icons.mic_none,
              color: listening ? K.glow : K.textSecondary),
          onPressed: busy ? null : onMic,
        ),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: !busy,
            autofocus: autofocus,
            minLines: 1,
            maxLines: 4,
            maxLength: 1000,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              hintText: listening
                  ? 'Listening…'
                  : autofocus
                      ? 'Ask about your flight…   Enter to send · Shift+Enter for a new line'
                      : 'Ask about your flight…',
              hintMaxLines: 1,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(horizontal: K.s4, vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: K.s2),
        Container(
          width: K.touch,
          height: K.touch,
          decoration: const BoxDecoration(gradient: K.primaryGradient, shape: BoxShape.circle),
          child: IconButton(
            tooltip: 'Send',
            icon: const Icon(Icons.arrow_upward, color: Colors.white),
            onPressed: busy ? null : () => onSend(),
          ),
        ),
      ]),
    );
  }
}
