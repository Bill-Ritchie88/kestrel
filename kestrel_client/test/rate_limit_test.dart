import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_client/api/kestrel_api.dart';

/// NFR-05: a 429 from the rate limit (with Retry-After) reads as a friendly
/// "wait N seconds"; the sign-in throttle's 429 keeps its own words.
void main() {
  http.Response tooFast(String retryAfter) => http.Response(
      jsonEncode({'detail': 'Rate limited.'}), 429,
      headers: {'retry-after': retryAfter, 'content-type': 'application/json'});

  Future<ApiException> failure(Future<Object?> Function(KestrelApi api) call, http.Response res) async {
    final api = KestrelApi(client: MockClient((_) async => res))..token = 't';
    try {
      await call(api);
    } on ApiException catch (e) {
      return e;
    }
    fail('expected an ApiException');
  }

  test('a rate-limited REST call says how long to wait', () async {
    final e = await failure((api) => api.clearChatHistory(), tooFast('3'));
    expect(e.status, 429);
    expect(e.message, "You're sending messages quickly. Please wait 3 seconds and try again.");
  });

  test('a rate-limited assistant turn (streamed) says the same, in the singular for 1 s', () async {
    final e = await failure((api) => api.chatStream('hi', const []).toList(), tooFast('1'));
    expect(e.message, "You're sending messages quickly. Please wait 1 second and try again.");
  });

  test('the sign-in throttle (no Retry-After) keeps its own message', () async {
    final e = await failure(
        (api) => api.login('A27Z99', 'Edwards'),
        http.Response(jsonEncode({'detail': 'Too many failed attempts for this booking. Try again in five minutes.'}),
            429));
    expect(e.message, 'Too many failed attempts for this booking. Try again in five minutes.');
  });
}
