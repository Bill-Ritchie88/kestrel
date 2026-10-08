import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_app/api/kestrel_api.dart';
import 'package:kestrel_app/format.dart';
import 'package:kestrel_app/main.dart';
import 'package:kestrel_app/state/session.dart';
import 'package:kestrel_app/theme.dart';

/// A booking shaped exactly like GET /api/me (src/kestrel/api/booking.py).
final _me = {
  'pnr_code': 'A27Z99',
  'booking_status': 'DISRUPTED',
  'passenger': {'first_name': 'Grace', 'last_name': 'Edwards', 'rewards_tier': 'GOLD'},
  'original_flight': {
    'flight_id': 'f-1',
    'flight_number': 'KQ100',
    'origin': 'NBO',
    'destination': 'MBA',
    'departure_local': '2026-10-11T16:21+03:00',
    'arrival_local': '2026-10-11T17:21+03:00',
    'status': 'CANCELLED',
    'disruption_reason': 'WEATHER',
  },
  'current_flight': null,
  'seat_number': '2A',
  'cabin_class': 'BUSINESS',
};

http.Client _backend({bool acceptLogin = true}) => MockClient((req) async {
      final path = req.url.path;
      if (path == '/api/auth/session') {
        return acceptLogin
            ? http.Response(
                jsonEncode({'access_token': 't', 'token_type': 'bearer', 'expires_in': 900}),
                200)
            : http.Response(jsonEncode({'detail': 'No booking matches that PNR and surname.'}),
                401);
      }
      if (path == '/api/me') {
        expect(req.headers['Authorization'], 'Bearer t');
        return http.Response(jsonEncode(_me), 200);
      }
      return http.Response('{}', 404);
    });

Future<void> _pump(WidgetTester tester, http.Client client) async {
  await tester.pumpWidget(KestrelApp(session: Session(api: KestrelApi(client: client))));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => K.useGoogleFonts = false); // no network in widget tests

  group('format', () {
    test('local times are shown as written, not converted', () {
      expect(hhmm('2026-10-11T16:21+03:00'), '16:21');
      expect(dayLabel('2026-10-11T16:21+03:00'), 'Sun 11 Oct');
      expect(dayOffset('2026-10-11T22:45+03:00', '2026-10-12T06:10+02:00'), '+1 day');
      expect(duration('2026-10-11T22:45+03:00', '2026-10-12T06:10+02:00'), '8h 25m');
      expect(money(2500, 'KES'), 'KES 2,500');
    });
  });

  testWidgets('sign-in validates the PNR before calling the API', (tester) async {
    var calls = 0;
    await _pump(tester, MockClient((_) async {
      calls++;
      return http.Response('{}', 500);
    }));
    await tester.tap(find.text('Find my booking'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your 6-character booking reference.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('wrong surname shows the server message', (tester) async {
    await _pump(tester, _backend(acceptLogin: false));
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Wrong');
    await tester.tap(find.text('Find my booking'));
    await tester.pumpAndSettle();
    expect(find.text('No booking matches that PNR and surname.'), findsOneWidget);
  });

  testWidgets('successful sign-in opens the chat with a greeting from the booking',
      (tester) async {
    await _pump(tester, _backend());
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
    await tester.tap(find.text('Find my booking'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget); // the composer
    expect(find.textContaining('Hello Grace'), findsOneWidget);
    expect(find.textContaining('because of weather'), findsWidgets); // greeting + card
    expect(find.text('Talk to a person'), findsOneWidget);
    expect(find.byTooltip('Speak your question'), findsOneWidget);
  });

  testWidgets('touch targets meet the 48 dp minimum on the sign-in screen', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _backend());
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    semantics.dispose();
  });

  test('theme text colours keep 4.5:1 contrast on the base surface', () {
    double lum(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final (hi, lo) = lum(a) > lum(b) ? (lum(a), lum(b)) : (lum(b), lum(a));
      return (hi + .05) / (lo + .05);
    }

    for (final c in [K.textPrimary, K.textSecondary, K.glow, K.teal, K.amber]) {
      expect(ratio(c, K.base), greaterThanOrEqualTo(4.5), reason: '$c on base');
    }
  });
}
