import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../format.dart';
import 'models.dart';
import 'streaming_client.dart';

/// A failed request, with the REST tier's own `detail` message when it sent
/// one. [status] follows IR-02 (401, 409, 422, 429, 502, 503 ...).
class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  bool get sessionExpired => status == 401;

  @override
  String toString() => message;
}

/// Thin HTTP client for the two services. Holds the session token; the
/// passenger's PNR is never sent again after login - the server reads it
/// from the token (NFR-03).
class KestrelApi {
  KestrelApi({http.Client? client, http.Client? streamClient})
      : _http = client ?? http.Client(),
        _streamHttp = streamClient ?? client ?? createStreamingClient();

  final http.Client _http;

  /// For the streamed chat: in a browser a fetch() client, whose response
  /// body arrives piece by piece.
  final http.Client _streamHttp;
  String? token;

  /// FR-09: the shared staff key, sent as X-Staff-Key on staff desk calls
  /// only. Held in memory, like the passenger token.
  String? staffKey;

  static const _timeout = Duration(seconds: 15);
  // An agent turn makes several model and tool calls (NFR-01: <= 15 s);
  // allow headroom before telling the passenger something went wrong.
  static const _agentTimeout = Duration(seconds: 45);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _api(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.apiBase}$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _send(Future<http.Response> request,
      {Duration timeout = _timeout}) async {
    final http.Response res;
    try {
      res = await request.timeout(timeout);
    } on TimeoutException {
      throw ApiException(504, 'The service took too long to respond. Please try again.');
    } catch (_) {
      throw ApiException(
          503, 'Kestrel can\'t be reached. Check that the services are running.');
    }
    Map<String, dynamic> body = {};
    if (res.body.isNotEmpty) {
      try {
        body = asMap(jsonDecode(res.body));
      } on FormatException {
        body = {}; // not JSON (e.g. a proxy error page): fall back below
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final detail = body['detail'];
    throw ApiException(
      res.statusCode,
      detail is String ? detail : _fallback(res.statusCode),
    );
  }

  static String _fallback(int status) => switch (status) {
        401 => 'Your session has ended. Please sign in again.',
        422 => 'Please check the details you entered.',
        429 => 'Too many attempts. Please wait a few minutes and try again.',
        503 => 'The service is temporarily unavailable.',
        _ => 'Something went wrong (error $status).',
      };

  // -- FR-01 ---------------------------------------------------------------

  Future<Map<String, dynamic>> login(String pnr, String surname) async {
    final body = await _send(_http.post(
      _api('/api/auth/session'),
      headers: _headers,
      body: jsonEncode({'pnr_code': pnr.trim().toUpperCase(), 'last_name': surname.trim()}),
    ));
    token = body['access_token'] as String?;
    return body;
  }

  void logout() => token = null;

  /// Social sign-in: exchanges a Supabase access token for a Kestrel token,
  /// linking the account to a booking the first time ([pnr], with or without
  /// [lastName]).
  Future<AccountSessionResult> accountSession(String accessToken, {String? pnr, String? lastName}) async {
    final body = await _send(_http.post(
      _api('/api/auth/account'),
      headers: _headers,
      body: jsonEncode({
        'access_token': accessToken,
        if (pnr != null) 'pnr_code': pnr.trim().toUpperCase(),
        if (lastName != null) 'last_name': lastName.trim(),
      }),
    ));
    learnCities(body['cities']);
    if (body['link_required'] == true) {
      return AccountSessionResult.link(asList(body['suggestions']).map(LinkSuggestion.new).toList());
    }
    token = body['access_token'] as String?;
    return AccountSessionResult.signedIn(asMap(body['passenger']), linked: body['linked'] != false);
  }

  /// "Unlink this booking": removes the signed-in account's own link.
  Future<void> unlinkAccount(String accessToken) => _send(_http.delete(
        _api('/api/auth/account/link'),
        headers: _headers,
        body: jsonEncode({'access_token': accessToken}),
      ));

  /// The whole trip in one call (the client's TripStore).
  Future<Trip> trip() async => Trip(await _send(_http.get(_api('/api/trip'), headers: _headers)));

  // -- FR-03 ---------------------------------------------------------------

  Future<Map<String, dynamic>> rebook(String flightId) => _send(_http.post(
        _api('/api/reaccommodate'),
        headers: _headers,
        body: jsonEncode({'target_flight_id': flightId}),
      ));

  // -- FR-05 ---------------------------------------------------------------

  Future<HandoffCase> requestPerson(String summary) async => HandoffCase(await _send(
        _http.post(
          _api('/api/handoff'),
          headers: _headers,
          body: jsonEncode({'trigger': 'PASSENGER_REQUEST', 'summary': summary}),
        ),
      ));

  // -- FR-09 staff desk --------------------------------------------------------

  Map<String, String> get _staffHeaders => {
        'Content-Type': 'application/json',
        if (staffKey != null) 'X-Staff-Key': staffKey!,
      };

  /// The case queue, newest first. [status] is OPEN, RESOLVED or ALL.
  Future<List<HandoffCase>> staffCases({String status = 'OPEN', int limit = 200}) async {
    final body = await _send(_http.get(
      _api('/api/staff/cases', {'status': status, 'limit': '$limit'}),
      headers: _staffHeaders,
    ));
    return asList(body['cases']).map(HandoffCase.new).toList();
  }

  Future<HandoffCase> resolveCase(int caseId, {required String by, required String note}) async =>
      HandoffCase(await _send(_http.post(
        _api('/api/staff/cases/$caseId/resolve'),
        headers: _staffHeaders,
        body: jsonEncode({'resolved_by': by, 'note': note}),
      )));

  // -- Conversation memory (the REST tier keeps it per booking) ---------------

  /// The booking's last 20 turns, oldest first.
  Future<List<HistoryTurn>> chatHistory() async {
    final body = await _send(_http.get(_api('/api/chat/history'), headers: _headers));
    return asList(body['turns']).map(HistoryTurn.new).toList();
  }

  /// "Start over": the saved conversation is deleted.
  Future<void> clearChatHistory() => _send(_http.delete(_api('/api/chat/history'), headers: _headers));

  // -- Agent service ---------------------------------------------------------

  Future<ChatReply> chat(String message, List<Map<String, String>> history, {String? intent}) async =>
      ChatReply(await _send(
        _http.post(
          Uri.parse('${AppConfig.agentBase}/api/chat'),
          headers: _headers,
          body: jsonEncode({'message': message, 'history': history, if (intent != null) 'intent': intent}),
        ),
        timeout: _agentTimeout,
      ));

  /// The same turn as [chat], as it happens (Server-Sent Events from POST
  /// /api/chat/stream): `status` while a tool runs, `delta` as the reply is
  /// written, `event` for each structured result, then `done` or `error`.
  /// [intent] is set only by the quick-reply chips (no model call then).
  Stream<ChatStreamEvent> chatStream(String message, List<Map<String, String>> history,
      {String? intent}) async* {
    // A turn can sit on one tool for a while; 45 s with nothing at all is a
    // failure (NFR-01 allows 15 s for a whole turn). The request is aborted
    // then, which ends the response stream with RequestAbortedException.
    final abort = Completer<void>();
    Timer? idle;
    void arm() {
      idle?.cancel();
      idle = Timer(_agentTimeout, () {
        if (!abort.isCompleted) abort.complete();
      });
    }

    const tooLong = 'The assistant took too long to answer. Please try again.';
    final request =
        http.AbortableRequest('POST', Uri.parse('${AppConfig.agentBase}/api/chat/stream'), abortTrigger: abort.future)
          ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
          ..body = jsonEncode({'message': message, 'history': history, if (intent != null) 'intent': intent});
    arm();
    try {
      final http.StreamedResponse res;
      try {
        res = await _streamHttp.send(request);
      } on http.RequestAbortedException {
        throw ApiException(504, tooLong);
      } catch (_) {
        throw ApiException(503, 'Kestrel can\'t be reached. Check that the services are running.');
      }
      if (res.statusCode != 200) {
        final text = await res.stream.bytesToString();
        Object? detail;
        try {
          detail = asMap(jsonDecode(text))['detail'];
        } on FormatException {
          detail = null;
        }
        throw ApiException(res.statusCode, detail is String ? detail : _fallback(res.statusCode));
      }
      String? kind;
      final data = StringBuffer();
      try {
        await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          arm();
          if (line.isEmpty) {
            if (kind != null) yield ChatStreamEvent(kind, asMap(jsonDecode(data.toString())));
            kind = null;
            data.clear();
          } else if (line.startsWith('event:')) {
            kind = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            data.write(line.substring(5).trim());
          }
        }
      } on http.RequestAbortedException {
        throw ApiException(504, tooLong);
      } on http.ClientException {
        throw ApiException(503, 'The connection to Kestrel was lost. Please try again.');
      }
    } finally {
      idle?.cancel();
    }
  }
}
