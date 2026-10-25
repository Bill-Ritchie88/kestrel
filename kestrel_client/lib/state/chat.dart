import 'package:flutter/foundation.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../format.dart';
import 'recommend.dart';
import 'session.dart';
import 'trip.dart';

class ChatMessage {
  ChatMessage.user(this.text)
      : fromUser = true,
        events = const [],
        totalMs = null,
        error = null,
        status = null,
        writing = false;
  ChatMessage.agent(this.text, {this.events = const [], this.totalMs})
      : fromUser = false,
        error = null,
        status = null,
        writing = false;
  ChatMessage.error(String this.error, {this.status})
      : fromUser = false,
        text = '',
        events = const [],
        totalMs = null,
        writing = false;

  /// A reply on its way (POST /api/chat/stream): [working] says what the
  /// assistant is doing until the first words arrive, then [text] grows.
  ChatMessage.streaming()
      : fromUser = false,
        text = '',
        events = [],
        totalMs = null,
        error = null,
        status = null,
        writing = true,
        working = 'Thinking\u2026';

  final bool fromUser;
  String text;
  List<AgentEvent> events;
  int? totalMs;
  final String? error;

  /// The HTTP status of a failed turn (503/504: the assistant is busy).
  final int? status;

  /// Still being written.
  bool writing;

  /// What the assistant is doing ("Checking flights…"), until the reply starts.
  String? working;
}

/// The conversation with the agent (M05/M08). It outlives the Assistant
/// section, so switching to Flights and back keeps the conversation, and the
/// "Ask Kestrel" field in the top bar can start a turn from any section.
class ChatController extends ChangeNotifier {
  ChatController(this.session, {required this.onError, this.trip}) {
    if (trip == null) {
      final b = session.booking;
      if (b != null) messages.add(ChatMessage.agent(greeting(b)));
    } else {
      // The greeting is written from the trip, so it waits for the trip -
      // and for the saved conversation, which replaces it when there is one.
      trip!.addListener(_greet);
      _loadHistory();
    }
  }

  /// When the saved conversation this one continues was last added to.
  String? continuingFrom;
  bool _historyLoaded = false;

  Future<void> _loadHistory() async {
    try {
      final turns = await session.api.chatHistory();
      if (_disposed) return;
      if (turns.isNotEmpty && messages.isEmpty) {
        for (final t in turns) {
          messages.add(t.fromUser ? ChatMessage.user(t.content) : ChatMessage.agent(t.content));
        }
        continuingFrom = turns.last.createdAt;
      }
    } catch (_) {
      // No memory to show (or none reachable): the conversation starts afresh.
    } finally {
      _historyLoaded = true;
      _greet();
      _notify();
    }
  }

  /// "Start over": the saved conversation is deleted and the greeting
  /// written again.
  Future<void> startOver() async {
    if (busy) return;
    try {
      await session.api.clearChatHistory();
    } catch (e) {
      final msg = onError(e);
      if (msg != null) addError(msg);
      return;
    }
    messages.clear();
    continuingFrom = null;
    lastFailed = null;
    suggestions = const [];
    _greetedFor = null;
    _greet();
    _notify();
  }

  final Session session;

  /// The passenger's trip: the greeting comes from it, and it is refreshed
  /// after a turn that rebooked or handed over.
  final TripStore? trip;

  /// The booking state the greeting and chips were written for, and whether
  /// the conversation is still only that greeting.
  String? _greetedFor;
  bool _onlyGreeting = false;

  /// Runs whenever the trip changes: a rebooking made on the Flights screen
  /// must not leave a greeting that still offers to rebook.
  void _greet() {
    final t = trip?.trip;
    if (t == null || !_historyLoaded) return;
    final state = '${t.booking.status}/${t.booking.current?.number}';
    if (state == _greetedFor) return;
    final changed = _greetedFor != null;
    _greetedFor = state;
    if (changed || suggestions.isEmpty) suggestions = t.suggestions;
    if (messages.isNotEmpty && !(changed && _onlyGreeting)) {
      _notify();
      return;
    }
    messages.clear();
    _onlyGreeting = true;
    final r = recommend(t);
    messages.add(ChatMessage.agent(
      greeting(t.booking, recommendation: r),
      // The recommended flight as a card under the greeting, with Choose.
      events: [
        if (r?.flight != null)
          AgentEvent('alternatives', {
            'alternatives': [r!.flight!.json]
          }),
      ],
    ));
    _notify();
  }

  /// Turns a failed call into a message, or null when the session ended and
  /// the passenger is being sent back to sign-in.
  final String? Function(Object error) onError;

  final messages = <ChatMessage>[];
  bool busy = false;
  String? lastFailed;
  String? _lastIntent;
  bool _disposed = false;

  /// UC2 opening message, written from the booking rather than by the model:
  /// it is instant and states only facts the REST tier returned. With a
  /// [recommendation] (Kestrel recommends) a disrupted passenger is told the
  /// best option and what they are owed, and asked whether to book it.
  static String greeting(Booking b, {Recommendation? recommendation}) {
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
          '${recommendation != null ? '${recommendation.text} ${recommendation.question}' : 'I can find you another flight, tell you what you\'re entitled to, or put you through to a person.'}';
    }
    return 'Hello $name. Your booking ${b.pnr} is ${titleCase(b.status)}. '
        'Ask me anything about your trip.';
  }

  String get lastQuestion =>
      messages.lastWhere((m) => m.fromUser, orElse: () => ChatMessage.user('')).text;

  List<Map<String, String>> _history() => [
        for (final m in messages)
          if (m.error == null && m.text.isNotEmpty && !m.writing)
            {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
      ];

  /// Next steps from the last reply (server suggestions), until the
  /// passenger asks something else.
  List<Suggestion> suggestions = const [];

  /// Sends a turn and shows the reply as it is written. [intent] comes only
  /// from a quick-reply chip: the agent service then runs that tool directly
  /// and answers without the model; typed text never carries one.
  Future<void> send(String raw, {String? intent}) async {
    final text = raw.trim();
    if (text.isEmpty || busy) return;
    final history = _history();
    _onlyGreeting = false;
    messages.add(ChatMessage.user(text));
    final reply = ChatMessage.streaming();
    messages.add(reply);
    busy = true;
    lastFailed = null;
    _lastIntent = intent;
    suggestions = const [];
    _notify();
    final recent = history.length > 20 ? history.sublist(history.length - 20) : history;
    try {
      ChatReply? done;
      try {
        await for (final e in session.api.chatStream(text, recent, intent: intent)) {
          if (_disposed) return;
          switch (e.type) {
            case 'status':
              reply.working = e.data['text'] as String?;
            case 'delta':
              reply.working = null;
              reply.text += e.data['text'] as String? ?? '';
            case 'event':
              reply.events.add(AgentEvent.fromJson(e.data));
            case 'done':
              done = ChatReply(e.data);
            case 'error':
              throw ApiException((e.data['status'] as num?)?.toInt() ?? 502,
                  e.data['detail'] as String? ?? 'Kestrel couldn\'t complete that request.');
          }
          _notify();
        }
      } on ApiException catch (e) {
        // An agent service without the streamed endpoint: the whole reply.
        if (e.status != 404) rethrow;
        done = await session.api.chat(text, recent, intent: intent);
      }
      if (_disposed) return;
      if (done == null) {
        throw ApiException(502, 'The reply was cut off. Please try again.');
      }
      reply
        ..text = done.reply
        ..events = done.events
        ..totalMs = done.totalMs
        ..working = null
        ..writing = false;
      suggestions = done.suggestions;
      // A rebooking or a hand-off changes the trip shown everywhere else.
      if (done.events.any((e) => e.type == 'rebooked' || e.type == 'handoff')) {
        if (trip != null) {
          trip!.refreshQuietly();
        } else if (done.events.any((e) => e.type == 'rebooked')) {
          await session.refresh();
        }
      }
    } catch (e) {
      if (_disposed) return;
      messages.remove(reply);
      final msg = onError(e);
      if (msg != null) {
        messages.add(ChatMessage.error(msg, status: e is ApiException ? e.status : null));
        lastFailed = text;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  /// Removes the error and the failed question, then asks again.
  void retry(ChatMessage failed) {
    final text = lastFailed;
    if (text == null || busy) return;
    messages
      ..remove(failed)
      ..removeLast();
    send(text, intent: _lastIntent);
  }

  void addError(String message) {
    messages.add(ChatMessage.error(message));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    trip?.removeListener(_greet);
    super.dispose();
  }
}
