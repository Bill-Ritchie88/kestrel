import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'models.dart';

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
  KestrelApi({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  String? token;

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

  Future<Booking> me() async =>
      Booking(await _send(_http.get(_api('/api/me'), headers: _headers)));

  // -- FR-03 ---------------------------------------------------------------

  Future<List<Flight>> alternatives({int limit = 5}) async {
    final body = await _send(_http.get(
      _api('/api/flights/alternatives', {'limit': '$limit'}),
      headers: _headers,
    ));
    return asList(body['alternatives']).map(Flight.new).toList();
  }

  Future<Map<String, dynamic>> rebook(String flightId) => _send(_http.post(
        _api('/api/reaccommodate'),
        headers: _headers,
        body: jsonEncode({'target_flight_id': flightId}),
      ));

  // -- FR-04 ---------------------------------------------------------------

  /// The rules' decision for this booking and the vouchers already issued.
  Future<({EntitlementDecision decision, List<Voucher> vouchers})> entitlements() async {
    final body = await _send(_http.get(_api('/api/entitlements'), headers: _headers));
    return (
      decision: EntitlementDecision(asMap(body['decision'])),
      vouchers: asList(body['vouchers']).map(Voucher.new).toList(),
    );
  }

  Future<List<Voucher>> vouchers() async {
    final body = await _send(_http.get(_api('/api/vouchers'), headers: _headers));
    return asList(body['vouchers']).map(Voucher.new).toList();
  }

  // -- FR-05 ---------------------------------------------------------------

  Future<HandoffCase> requestPerson(String summary) async => HandoffCase(await _send(
        _http.post(
          _api('/api/handoff'),
          headers: _headers,
          body: jsonEncode({'trigger': 'PASSENGER_REQUEST', 'summary': summary}),
        ),
      ));

  Future<List<HandoffCase>> myCases() async {
    final body = await _send(_http.get(_api('/api/handoff'), headers: _headers));
    return asList(body['cases']).map(HandoffCase.new).toList();
  }

  // -- Agent service ---------------------------------------------------------

  Future<ChatReply> chat(String message, List<Map<String, String>> history) async =>
      ChatReply(await _send(
        _http.post(
          Uri.parse('${AppConfig.agentBase}/api/chat'),
          headers: _headers,
          body: jsonEncode({'message': message, 'history': history}),
        ),
        timeout: _agentTimeout,
      ));
}
