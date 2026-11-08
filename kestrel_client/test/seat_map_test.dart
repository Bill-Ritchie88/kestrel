import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_client/api/kestrel_api.dart';
import 'package:kestrel_client/api/models.dart';
import 'package:kestrel_client/screens/seat_map_screen.dart';
import 'package:kestrel_client/state/public.dart';
import 'package:kestrel_client/state/session.dart';
import 'package:kestrel_client/state/shell.dart';
import 'package:kestrel_client/theme.dart';

/// FR-16 seat map (M10): GET /api/flights/{id}/seats and POST
/// /api/reaccommodate with seat_id, against a fake REST tier.
final _flight = Flight({
  'flight_id': 'f-2',
  'flight_number': 'KQ102',
  'origin': 'NBO',
  'destination': 'MBA',
  'departure_local': '2026-10-11T19:00+03:00',
  'arrival_local': '2026-10-11T20:00+03:00',
  'cabin_class': 'ECONOMY',
  'available_seats': 4,
  'aircraft_type': '738',
});

class _Backend {
  _Backend({this.seatTaken = false});

  /// The first rebooking with a seat is refused: someone confirmed it first.
  bool seatTaken;
  final taken = <String>{'5B'};
  int seatMapCalls = 0;
  final rebookBodies = <Map<String, dynamic>>[];

  Map<String, dynamic> _seats() => {
        'flight_id': 'f-2',
        'cabin_class': 'ECONOMY',
        'layout': 'ABC DEF',
        'seats': [
          for (final row in [5, 6])
            for (final l in 'ABCDEF'.split(''))
              {
                'seat_id': 's-$row$l',
                'seat_number': '$row$l',
                'row': row,
                'letter': l,
                'status': taken.contains('$row$l') ? 'taken' : 'free',
              },
        ],
      };

  http.Client get client => MockClient((req) async {
        http.Response json(Object body, [int code = 200, Map<String, String> headers = const {}]) =>
            http.Response(jsonEncode(body), code, headers: headers);
        if (req.url.path == '/api/flights/f-2/seats') {
          seatMapCalls++;
          return json(_seats());
        }
        if (req.url.path == '/api/reaccommodate') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          rebookBodies.add(body);
          if (seatTaken && body['seat_id'] != null) {
            seatTaken = false;
            taken.add((body['seat_id'] as String).substring(2)); // someone else has it now
            return json({'detail': 'That seat was just taken. Please pick another.'}, 409,
                {'x-refusal-reason': 'SEAT_TAKEN'});
          }
          final seat = (body['seat_id'] as String?)?.substring(2) ?? '5A';
          return json({'success': true, 'assigned_seat': seat, 'message': 'ok', 'booking': null});
        }
        return http.Response('{}', 404);
      });
}

Future<void> _pump(WidgetTester tester, _Backend backend, {Size screen = const Size(375, 812)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = screen;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = Session(api: KestrelApi(client: backend.client))..api.token = 't';
  await tester.pumpWidget(SessionScope(
    session: session,
    child: ShellScope(
      shell: ShellController(),
      child: PublicScope(
        public: PublicController(),
        child: MaterialApp(theme: kestrelTheme(), home: SeatMapScreen(flight: _flight)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _seat(String number) => find.byKey(ValueKey('seat-$number'));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final (name, size) in [('phone', const Size(375, 812)), ('laptop', const Size(1440, 900))]) {
    testWidgets('the cabin as a grid with aisle, legend and 48 px seats ($name)', (tester) async {
      await _pump(tester, _Backend(), screen: size);
      expect(find.text('Choose your seat'), findsOneWidget);
      for (final label in ['Free', 'Taken', 'Selected']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.bySemanticsLabel('Seat 5A, free'), findsOneWidget);
      expect(find.bySemanticsLabel('Seat 5B, taken'), findsOneWidget);
      final a = tester.getRect(_seat('5A')), c = tester.getRect(_seat('5C')), d = tester.getRect(_seat('5D'));
      expect(a.width, greaterThanOrEqualTo(K.touch));
      expect(a.height, greaterThanOrEqualTo(K.touch));
      // The aisle: the gap between C and D is wider than between seats.
      expect(d.left - c.right, greaterThan(c.left - tester.getRect(_seat('5B')).right + 8));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a free seat can be selected, a taken one cannot', (tester) async {
    await _pump(tester, _Backend());
    expect(find.text('Choose a seat'), findsOneWidget);

    await _tap(tester, _seat('5B')); // taken
    expect(find.text('Choose a seat'), findsOneWidget);

    await _tap(tester, _seat('5C'));
    expect(find.text('Continue with seat 5C'), findsOneWidget);
    expect(find.bySemanticsLabel('Seat 5C, selected'), findsOneWidget);

    await _tap(tester, _seat('5C')); // tap again to clear
    expect(find.text('Choose a seat'), findsOneWidget);
  });

  testWidgets('the chosen seat is shown on Confirm and sent with the rebooking', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    await _tap(tester, _seat('6E'));
    await _tap(tester, find.text('Continue with seat 6E'));

    expect(find.text('Confirm your new flight'), findsOneWidget);
    expect(find.text('Seat 6E · Economy'), findsOneWidget);
    await _tap(tester, find.text('Confirm rebooking'));
    expect(backend.rebookBodies.single, {'target_flight_id': 'f-2', 'seat_id': 's-6E'});
    expect(find.text("You're rebooked"), findsOneWidget);
    expect(find.textContaining('Seat 6E'), findsOneWidget);
  });

  testWidgets('409 SEAT_TAKEN: back on the map with the message, refreshed, pick again', (tester) async {
    final backend = _Backend(seatTaken: true);
    await _pump(tester, backend);
    await _tap(tester, _seat('5C'));
    await _tap(tester, find.text('Continue with seat 5C'));
    await _tap(tester, find.text('Confirm rebooking'));

    expect(find.text('Choose your seat'), findsOneWidget);
    expect(find.text(SeatMapScreen.takenMessage), findsOneWidget);
    expect(backend.seatMapCalls, 2); // reloaded
    expect(find.bySemanticsLabel('Seat 5C, taken'), findsOneWidget);
    expect(find.text('Choose a seat'), findsOneWidget); // the selection is cleared

    await _tap(tester, _seat('5D'));
    await _tap(tester, find.text('Continue with seat 5D'));
    await _tap(tester, find.text('Confirm rebooking'));
    expect(find.text("You're rebooked"), findsOneWidget);
    expect(backend.rebookBodies.last['seat_id'], 's-5D');
  });

  testWidgets('"Let Kestrel choose" rebooks without a seat', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    await _tap(tester, find.text('Let Kestrel choose'));
    expect(find.text('Confirm your new flight'), findsOneWidget);
    expect(find.textContaining('Seat '), findsNothing);
    await _tap(tester, find.text('Confirm rebooking'));
    expect(backend.rebookBodies.single, {'target_flight_id': 'f-2'});
  });
}
