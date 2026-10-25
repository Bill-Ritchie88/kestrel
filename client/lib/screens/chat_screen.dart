import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/models.dart';
import '../format.dart';
import '../state/chat.dart';
import '../state/shell.dart';
import '../state/trip.dart';
import '../theme.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/layout.dart';
import '../widgets/next_steps.dart';
import '../widgets/system_state.dart';
import 'confirm_screen.dart';

/// M05 / M08 · Assistant (UC2, UC3). Each turn goes to the agent service
/// (:8001), which calls the REST tier's tools with this passenger's token. The
/// structured results it returns (flights, rebooking, clauses, entitlements,
/// hand-off) are drawn as cards under the reply, from the same data the
/// model saw, so the screen never depends on the model's wording for facts.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat, required this.onPerson});
  final ChatController chat;
  final VoidCallback onPerson;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// The conversation card's widest (about 70 characters per bubble line).
const _chatCardMax = 880.0;

/// The chips until the server's suggestions arrive (with the trip). Those
/// with an intent are answered by the agent service straight from the
/// matching tool, with no model call (instant); the refund question needs
/// the policy, so it goes to the model.
final _quickReplies = [
  Suggestion({'label': 'Find me another flight', 'intent': 'alternatives'}),
  Suggestion({'label': 'What am I entitled to?', 'intent': 'entitlements'}),
  Suggestion({'label': 'Can I get a refund instead?', 'message': 'Can I get a refund instead?'}),
];

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  // Enter sends, Shift+Enter starts a new line - what people expect from a
  // chat box in a browser.
  late final _inputFocus = FocusNode(onKeyEvent: _onComposerKey);
  final _scroll = ScrollController();
  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  ChatController get _chat => widget.chat;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_onChat);
    _scrollToEnd(animate: false);
  }

  @override
  void dispose() {
    _chat.removeListener(_onChat);
    _speech.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChat() {
    if (!mounted) return;
    setState(() {});
    _scrollToEnd();
  }

  void _scrollToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final reduce = MediaQuery.of(context).disableAnimations;
      final end = _scroll.position.maxScrollExtent;
      reduce || !animate
          ? _scroll.jumpTo(end)
          : _scroll.animateTo(end, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
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

  void _ask(String text, {String? intent}) => _send(text, intent);

  /// Chips show under the greeting and under each finished reply.
  bool get _showChips {
    final last = _chat.messages.isEmpty ? null : _chat.messages.last;
    return last == null || (!last.fromUser && !last.writing);
  }

  /// The server's next steps, or the defaults until they arrive; "Talk to a
  /// person" stays reachable unless a case is already open.
  List<Suggestion> get _chips {
    final list = _chat.suggestions.isNotEmpty ? _chat.suggestions : _quickReplies;
    final hasPerson = list.any((s) => s.intent == 'person' || s.intent == 'case');
    return [
      ...list,
      if (!hasPerson) Suggestion({'label': 'Talk to a person', 'intent': 'person'}),
    ];
  }

  /// [intent] only from a chip; what the passenger types never has one.
  Future<void> _send([String? preset, String? intent]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _chat.busy) return;
    if (_listening) await _speech.stop();
    if (!mounted) return;
    setState(() => _listening = false);
    if (preset == null) _input.clear();
    await _chat.send(text, intent: intent);
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

  Future<void> _choose(Flight f) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConfirmScreen(flight: f)));

  // -- Event cards ------------------------------------------------------------

  List<Widget> _eventCards(AgentEvent e) {
    final d = e.data;
    final shell = ShellScope.read(context);
    switch (e.type) {
      case 'alternatives':
        final flights = asList(d['alternatives']).map(Flight.new).toList();
        if (flights.isEmpty) return const [];
        return [
          for (final (i, f) in flights.take(3).indexed)
            FlightOptionCard(flight: f, recommended: i == 0, onSelect: () => _choose(f)),
          if (flights.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: LinkButton(
                label: 'See all ${flights.length} flights',
                onPressed: () => shell.go(Section.flights),
              ),
            ),
        ];
      case 'rebooked':
        final booking = asMap(d['booking']);
        final vouchers = asList(asMap(d['entitlements'])['vouchers'])
            .map(Voucher.new)
            .where((v) => v.isLive)
            .toList();
        return [
          if (booking.isNotEmpty) TripTicket(booking: Booking(booking), compact: true),
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
          Align(
            alignment: Alignment.centerLeft,
            child: LinkButton(label: 'Open my vouchers', onPressed: () => shell.go(Section.vouchers)),
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

  Widget _messageView(ChatMessage m) {
    if (m.error != null) {
      final canRetry = _chat.lastFailed != null && !_chat.busy && identical(m, _chat.messages.last);
      // 503/504: the agent service is down or overloaded, but the rest of the
      // app is not - say so, and offer the ways forward.
      if (m.status == 503 || m.status == 504) {
        return SystemStateCard.assistantBusy(
          onRetry: canRetry ? () => _chat.retry(m) : null,
          onTrip: () => ShellScope.read(context).go(Section.trip),
          onPerson: widget.onPerson,
        );
      }
      return ErrorNotice(message: m.error!, onRetry: canRetry ? () => _chat.retry(m) : null);
    }
    final cards = [for (final e in m.events) ..._eventCards(e)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A streamed reply: what the assistant is doing until its first
        // words, then the words as they arrive, with a cursor.
        if (m.writing && m.text.isEmpty) ThinkingBubble(label: m.working),
        if (m.text.isNotEmpty) ChatBubble(text: m.text, fromUser: m.fromUser, writing: m.writing),
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
    // The trip panel waits for the whole trip (it draws the ticket).
    final booking = TripScope.of(context).trip?.booking;
    return LayoutBuilder(builder: (context, c) {
      // Beside the sidebar the conversation sits in a card, with the trip in
      // a panel next to it when there is room; on a phone it fills the screen.
      final inCard = MediaQuery.sizeOf(context).width >= Breakpoints.wide;
      final withPanel = inCard && c.maxWidth >= Breakpoints.twoPane + 120;
      final conversation = _conversation(inCard: inCard);
      if (!inCard) return conversation;
      final panel = withPanel && booking != null;
      // The card stops at a readable width; on a very wide screen the card
      // and the trip panel stay together in the middle.
      return Padding(
        padding: const EdgeInsets.all(K.s5),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _chatCardMax + (panel ? K.s5 + 340 : 0)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: K.surface,
                    borderRadius: BorderRadius.circular(K.radiusLg),
                    border: Border.all(color: K.hairline),
                  ),
                  child: conversation,
                ),
              ),
              if (panel) ...[
                const SizedBox(width: K.s5),
                SizedBox(width: 340, child: _TripPanel(booking: booking, onAsk: _send, onPerson: widget.onPerson)),
              ],
            ]),
          ),
        ),
      );
    });
  }

  Widget _conversation({required bool inCard}) {
    final t = Theme.of(context).textTheme;
    final busy = _chat.busy;
    return LayoutBuilder(builder: (context, c) {
      final padding = inCard
          ? const EdgeInsets.fromLTRB(K.s5, K.s4, K.s5, K.s4)
          : pagePadding(c.maxWidth, maxWidth: Breakpoints.chat, top: K.s3);
      return Column(children: [
        if (inCard)
          Container(
            padding: const EdgeInsets.fromLTRB(K.s5, K.s4, K.s3, K.s4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: K.hairline))),
            child: Row(children: [
              const KestrelMark(size: 38),
              const SizedBox(width: K.s3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text('Kestrel assistant', style: t.titleMedium)),
                  Row(children: [
                    Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(color: K.teal, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('Online · answers from your booking and the conditions of carriage',
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: K.textSecondary)),
                    ),
                  ]),
                ]),
              ),
              IconButton(
                tooltip: 'Talk to a person',
                icon: const Icon(Icons.support_agent, color: K.textSecondary),
                onPressed: widget.onPerson,
              ),
            ]),
          ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: padding,
            children: [
              if (_chat.continuingFrom != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: K.s4),
                  child: _Continuing(since: _chat.continuingFrom!, onStartOver: _chat.startOver),
                ),
              for (final (i, m) in _chat.messages.indexed)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : K.s4),
                  child: _messageView(m),
                ),
            ],
          ),
        ),
        // Next steps (the server's suggestions after each reply) wrap onto a
        // second line rather than scrolling sideways, so "Talk to a person"
        // is never hidden off-screen.
        if (!busy && _showChips)
          Padding(
            padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, K.s2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: K.s2,
                runSpacing: K.s2,
                children: [
                  for (final s in _chips)
                    ActionChip(
                      avatar: suggestionIcon(s) == null ? null : Icon(suggestionIcon(s), size: 18),
                      label: Text(s.label),
                      onPressed: () => runSuggestion(context, s, ask: _ask),
                      backgroundColor: K.inset,
                      side: BorderSide(color: s.intent == 'person' ? K.hairline : K.crimsonStroke),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                    ),
                ],
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: inCard ? K.surface : K.base,
            border: const Border(top: BorderSide(color: K.hairline)),
          ),
          child: CentredBar(
            maxWidth: inCard ? double.infinity : Breakpoints.chat + 2 * K.s4,
            child: _Composer(
              controller: _input,
              focusNode: _inputFocus,
              busy: busy,
              listening: _listening,
              autofocus: inCard,
              onSend: _send,
              onMic: _toggleMic,
            ),
          ),
        ),
      ]);
    });
  }
}

/// Above a conversation brought back from an earlier visit.
class _Continuing extends StatelessWidget {
  const _Continuing({required this.since, required this.onStartOver});
  final String since;
  final Future<void> Function() onStartOver;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Row(children: [
        const Icon(Icons.history, size: 18, color: K.textSecondary),
        const SizedBox(width: K.s2),
        Expanded(
          child: Text('Continuing your conversation from ${dayTime(since)}',
              style: t.bodySmall?.copyWith(color: K.textSecondary)),
        ),
        LinkButton(label: 'Start over', icon: Icons.restart_alt, onPressed: onStartOver),
      ]),
    );
  }
}

/// Beside the conversation on a wide screen: the trip, questions to try,
/// and a person.
class _TripPanel extends StatelessWidget {
  const _TripPanel({required this.booking, required this.onAsk, required this.onPerson});
  final Booking booking;
  final Future<void> Function([String?, String?]) onAsk;
  final VoidCallback onPerson;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(children: [
      const SectionLabel('Your trip'),
      const SizedBox(height: K.s3),
      TripTicket(booking: booking, compact: true),
      const SizedBox(height: K.s5),
      KCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text('Try asking', style: t.titleMedium)),
          const SizedBox(height: K.s2),
          for (final (q, intent) in [
            if (booking.isDisrupted) ('Find me another flight', 'alternatives'),
            ('What am I entitled to?', 'entitlements'),
            ('Can I get a refund instead?', null),
            ('Can I take a later flight?', null),
          ])
            Padding(
              padding: const EdgeInsets.only(top: K.s2),
              child: Material(
                color: K.inset,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onAsk(q, intent),
                  child: SizedBox(
                    height: K.touch,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: K.s3),
                      child: Row(children: [
                        Expanded(child: Text(q, style: t.bodyMedium)),
                        const Icon(Icons.north_east, size: 16, color: K.glow),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: K.s4),
      SecondaryButton(label: 'Talk to a person', icon: Icons.support_agent, onPressed: onPerson),
    ]);
  }
}

/// Input bar: dictation, text and send. Dictation fills the field so the
/// passenger can check the words before sending.
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
      padding: const EdgeInsets.fromLTRB(K.s3, K.s3, K.s3, K.s3),
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
