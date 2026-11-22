import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_client/api/kestrel_api.dart';
import 'package:kestrel_client/api/models.dart';
import 'package:kestrel_client/screens/rebook_proposal_card.dart';
import 'package:kestrel_client/screens/seat_map_screen.dart';
import 'package:kestrel_client/state/public.dart';
import 'package:kestrel_client/state/session.dart';
import 'package:kestrel_client/state/shell.dart';
import 'package:kestrel_client/theme.dart';
import 'package:kestrel_client/widgets/cards.dart';
import 'package:kestrel_client/widgets/common.dart';

/// Connecting journeys through Nairobi (migration 015): the legs and the
/// missed connection on the ticket, journey options, a seat per leg, and one
/// confirmation for both legs.

Map<String, dynamic> _journey({bool firstKept = false}) => {
      'flight_id': 'f-1',
      'flight_number': 'KQ601',
      'origin': 'MBA',
      'destination': 'NBO',
      'departure_local': '2026-12-01T09:00+03:00',
      'arrival_local': '2026-12-01T10:00+03:00',
      'cabin_class': 'ECONOMY',
      'available_seats': 6,
      'kept': firstKept,
      'final_destination': 'EBB',
      'connection_minutes': 90,
      'onward': {
        'flight_id': 'f-2',
        'flight_number': 'KQ412',
        'origin': 'NBO',
        'destination': 'EBB',
        'departure_local': '2026-12-01T11:30+03:00',
        'arrival_local': '2026-12-01T12:40+03:00',
        'available_seats': 6,
        'kept': false,
      },
    };

final _booking = Booking({
  'pnr_code': '7J0001',
  'booking_status': 'DISRUPTED',
  'passenger': {'first_name': 'Conn', 'last_name': 'Test', 'rewards_tier': 'BLUE'},
  'original_flight': {
    'flight_id': 'o-1', 'flight_number': 'KQ603', 'origin': 'MBA', 'destination': 'NBO',
    'departure_local': '2026-12-01T06:00+03:00', 'arrival_local': '2026-12-01T07:00+03:00',
    'status': 'CANCELLED', 'disruption_reason': 'TECHNICAL',
  },
  'current_flight': null,
  'seat_number': '12A',
  'cabin_class': 'ECONOMY',
  'final_destination': 'EBB',
  'onward_flight': {'flight_id': 'o-2', 'flight_number': 'KQ410', 'origin': 'NBO', 'destination': 'EBB'},
  'legs': [
    {'leg': 1, 'flight_number': 'KQ603', 'origin': 'MBA', 'destination': 'NBO',
     'departure_local': '2026-12-01T06:00+03:00', 'leg_status': 'CANCELLED'},
    {'leg': 2, 'flight_number': 'KQ410', 'origin': 'NBO', 'destination': 'EBB',
     'departure_local': '2026-12-01T08:00+03:00', 'leg_status': 'MISSED_CONNECTION'},
  ],
}); // fmt: skip

class _Backend {
  final seatMapPaths = <String>[];
  final rebookBodies = <Map<String, dynamic>>[];

  Map<String, dynamic> _seats(String flight) => {
        'flight_id': flight,
        'cabin_class': 'ECONOMY',
        'layout': 'ABC DEF',
        'seats': [
          for (final l in 'ABCDEF'.split(''))
            {'seat_id': '$flight-5$l', 'seat_number': '5$l', 'row': 5, 'letter': l, 'status': 'free'},
        ],
      };

  http.Client get client => MockClient((req) async {
        final m = RegExp(r'^/api/flights/(f-\d)/seats$').firstMatch(req.url.path);
        if (m != null) {
          seatMapPaths.add(req.url.path);
          return http.Response(jsonEncode(_seats(m.group(1)!)), 200);
        }
        if (req.url.path == '/api/reaccommodate') {
          rebookBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode({'success': true, 'assigned_seat': '5A', 'onward_seat': '5C', 'booking': null}), 200);
        }
        return http.Response('{}', 404);
      });
}

Future<void> _pump(WidgetTester tester, Widget home, {_Backend? backend, bool page = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = Session(api: KestrelApi(client: (backend ?? _Backend()).client))..api.token = 't';
  await tester.pumpWidget(SessionScope(
    session: session,
    child: ShellScope(
      shell: ShellController(),
      child: PublicScope(
        public: PublicController(),
        child: MaterialApp(
            theme: kestrelTheme(), home: page ? home : Scaffold(body: SingleChildScrollView(child: home))),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ticket shows both legs and the missed connection', (tester) async {
    await _pump(tester, TripTicket(booking: _booking));
    expect(find.textContaining('Your journey to'), findsOneWidget);
    expect(find.textContaining('Leg 1 · KQ603'), findsOneWidget);
    expect(find.textContaining('Leg 2 · KQ410'), findsOneWidget);
    expect(find.text('MISSED CONNECTION'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a journey option shows its onward flight and the connection', (tester) async {
    await _pump(tester, FlightOptionCard(flight: Flight(_journey()), onSelect: () {}));
    expect(find.text('Then KQ412'), findsOneWidget);
    expect(find.textContaining('90 min to connect'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Then KQ412')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a seat on each leg, then one confirmation for both', (tester) async {
    final backend = _Backend();
    await _pump(tester, SeatMapScreen(flight: Flight(_journey())), backend: backend, page: true);
    expect(find.text('Choose your seat · flight 1 of 2'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('seat-5A')));
    await _tap(tester, find.text('Continue with seat 5A'));

    expect(find.text('Choose your seat · flight 2 of 2'), findsOneWidget);
    expect(backend.seatMapPaths, ['/api/flights/f-1/seats', '/api/flights/f-2/seats']);
    await _tap(tester, find.byKey(const ValueKey('seat-5C')));
    await _tap(tester, find.text('Continue with seat 5C'));

    expect(find.text('Confirm your new journey'), findsOneWidget);
    expect(find.text('Seats 5A and 5C · Economy'), findsOneWidget);
    await _tap(tester, find.text('Confirm rebooking'));
    expect(backend.rebookBodies.single, {
      'target_flight_id': 'f-1',
      'seat_id': 'f-1-5A',
      'onward_flight_id': 'f-2',
      'onward_seat_id': 'f-2-5C',
    });
    expect(find.text("You're rebooked"), findsOneWidget);
    expect(find.textContaining('Seats 5A and 5C'), findsOneWidget);
  });

  testWidgets('a kept first leg needs no new seat: only the onward map', (tester) async {
    final backend = _Backend();
    await _pump(tester, SeatMapScreen(flight: Flight(_journey(firstKept: true))), backend: backend, page: true);
    expect(find.text('Choose your seat'), findsOneWidget); // one map, no "of 2"
    expect(backend.seatMapPaths, ['/api/flights/f-2/seats']);
    await _tap(tester, find.text('Let Kestrel choose'));
    await _tap(tester, find.text('Confirm rebooking'));
    expect(backend.rebookBodies.single, {'target_flight_id': 'f-1', 'onward_flight_id': 'f-2'});
  });

  testWidgets("the assistant's journey proposal confirms both legs with its token", (tester) async {
    final backend = _Backend();
    await _pump(
        tester,
        RebookProposalCard(proposal: {
          'flight': _journey(),
          'seat_id': null,
          'onward_seat_id': null,
          'confirmation_token': 'proposal.sig',
          'expires_in': 300,
        }),
        backend: backend);
    expect(find.textContaining('Both flights are rebooked together'), findsOneWidget);
    await _tap(tester, find.widgetWithText(PrimaryButton, 'Confirm rebooking'));
    expect(backend.rebookBodies.single, {
      'target_flight_id': 'f-1',
      'confirmation_token': 'proposal.sig',
      'onward_flight_id': 'f-2',
    });
  });

  group('labels name the leg that broke', () {
    Booking with_(Map<String, dynamic> over) => Booking({..._booking.json, ...over});
    final firstOk = {..._booking.json['original_flight'] as Map<String, dynamic>, 'status': 'SCHEDULED',
        'disruption_reason': null};
    final onwardCancelled = {..._booking.json['onward_flight'] as Map<String, dynamic>, 'status': 'CANCELLED',
        'departure_local': '2026-12-01T08:00+03:00'};

    testWidgets('onward leg cancelled: the tracker names the onward flight', (tester) async {
      await _pump(tester, RecoveryTracker(booking: with_({'original_flight': firstOk, 'onward_flight': onwardCancelled})));
      expect(find.text('Flight cancelled'), findsOneWidget);
      expect(find.textContaining('KQ410'), findsOneWidget);
      expect(find.textContaining('KQ603'), findsNothing);
    });

    testWidgets('first leg delayed: the tracker says delayed, not cancelled', (tester) async {
      await _pump(tester, RecoveryTracker(booking: with_({
        'original_flight': {...firstOk, 'status': 'DELAYED'},
      })));
      expect(find.text('Flight delayed'), findsOneWidget);
      expect(find.text('Flight cancelled'), findsNothing);
    });

    testWidgets('rebooked connection: "Replaces" names the cancelled onward leg', (tester) async {
      await _pump(tester, TripTicket(booking: with_({
        'booking_status': 'REACCOMMODATED',
        'original_flight': firstOk,
        'onward_flight': onwardCancelled,
        'current_flight': {...firstOk, 'flight_id': 'n-1', 'flight_number': 'KQ609'},
      })));
      final replaces = find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().startsWith('Replaces '));
      expect(replaces, findsOneWidget);
      expect((tester.widget(replaces) as RichText).text.toPlainText(), 'Replaces KQ410, cancelled.');
    });

    testWidgets('cancelled for a refund: "Refund requested", no travel step', (tester) async {
      await _pump(tester, RecoveryTracker(booking: with_({'booking_status': 'CANCELLED'})));
      expect(find.text('Refund requested'), findsOneWidget);
      expect(find.text('Travel'), findsNothing);
    });
  });
}
