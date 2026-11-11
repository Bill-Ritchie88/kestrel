import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_client/api/kestrel_api.dart';
import 'package:kestrel_client/screens/rebook_proposal_card.dart';
import 'package:kestrel_client/state/public.dart';
import 'package:kestrel_client/state/session.dart';
import 'package:kestrel_client/state/shell.dart';
import 'package:kestrel_client/theme.dart';
import 'package:kestrel_client/widgets/common.dart';

/// FR-17: the assistant's "Confirm rebooking" card. Only the passenger's tap
/// sends the proposal's token to POST /api/reaccommodate.
final _proposal = {
  'flight': {
    'flight_id': 'f-2',
    'flight_number': 'KQ102',
    'origin': 'NBO',
    'destination': 'MBA',
    'departure_local': '2026-10-11T19:00+03:00',
    'arrival_local': '2026-10-11T20:00+03:00',
    'cabin_class': 'ECONOMY',
    'available_seats': 4,
  },
  'seat_id': null,
  'confirmation_token': 'proposal.sig',
  'expires_in': 300,
};

class _Backend {
  _Backend({this.refuse = false});
  final bool refuse;
  final rebookBodies = <Map<String, dynamic>>[];
  final paths = <String>[];

  http.Client get client => MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/api/reaccommodate') {
          rebookBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (refuse) {
            return http.Response(
                jsonEncode({'detail': 'The confirmation has expired. Ask again for this flight.'}), 403,
                headers: {'x-refusal-reason': 'CONFIRMATION_INVALID'});
          }
          return http.Response(jsonEncode({'success': true, 'assigned_seat': '5A', 'booking': null}), 200);
        }
        if (req.url.path == '/api/flights/f-2/seats') {
          return http.Response(
              jsonEncode({'flight_id': 'f-2', 'cabin_class': 'ECONOMY', 'layout': 'AB', 'seats': []}), 200);
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
        child: MaterialApp(
          theme: kestrelTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: RebookProposalCard(proposal: _proposal),
            ),
          ),
        ),
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
  for (final (name, size) in [('phone', const Size(375, 812)), ('laptop', const Size(1440, 900))]) {
    testWidgets('the card shows the flight and changes nothing until tapped ($name)', (tester) async {
      final backend = _Backend();
      await _pump(tester, backend, screen: size);
      expect(find.text('Confirm rebooking'), findsNWidgets(2)); // heading and button
      expect(find.textContaining('Nothing changes until you confirm'), findsOneWidget);
      expect(find.textContaining('KQ102'), findsWidgets);
      expect(backend.paths, isEmpty);
      final button = tester.getSize(find.widgetWithText(SecondaryButton, 'Choose a seat'));
      expect(button.height, greaterThanOrEqualTo(K.touch));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Confirm sends the proposal token and shows the rebooking', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    await _tap(tester, find.widgetWithText(PrimaryButton, 'Confirm rebooking'));
    expect(backend.rebookBodies.single, {'target_flight_id': 'f-2', 'confirmation_token': 'proposal.sig'});
    expect(find.text("You're rebooked"), findsOneWidget);
  });

  testWidgets('a refused token is explained and nothing is shown as rebooked', (tester) async {
    final backend = _Backend(refuse: true);
    await _pump(tester, backend);
    await _tap(tester, find.widgetWithText(PrimaryButton, 'Confirm rebooking'));
    expect(find.textContaining('The confirmation has expired'), findsOneWidget);
    expect(find.text("You're rebooked"), findsNothing);
  });

  testWidgets('"Choose a seat" opens the seat map instead', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend);
    await _tap(tester, find.text('Choose a seat'));
    expect(find.text('Choose your seat'), findsOneWidget);
    expect(backend.rebookBodies, isEmpty);
  });
}
