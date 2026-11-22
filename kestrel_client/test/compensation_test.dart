import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_client/api/kestrel_api.dart';
import 'package:kestrel_client/api/models.dart';
import 'package:kestrel_client/screens/staff_claims.dart';
import 'package:kestrel_client/screens/trip_screen.dart';
import 'package:kestrel_client/state/public.dart';
import 'package:kestrel_client/state/session.dart';
import 'package:kestrel_client/state/shell.dart';
import 'package:kestrel_client/state/trip.dart';
import 'package:kestrel_client/theme.dart';
import 'package:kestrel_client/widgets/claims.dart';

/// Migration 016: claiming compensation, the claim's status, cancel and
/// refund, a delay, no seats left, a second disruption, and the staff desk's
/// Compensation tab.

const _cash = {
  'entitlement_type': 'CASH_COMPENSATION',
  'label': 'Cash compensation',
  'status': 'ELIGIBLE',
  'rule_id': 'R4_COMPENSATION',
  'basis': 'EU261 Art. 5(1)(c), Art. 7(1)',
  'explanation': '6,600 km route.',
  'amount': 600.0,
  'currency': 'EUR',
};

Map<String, dynamic> _claim({String status = 'CLAIMED', String kind = 'COMPENSATION', int id = 7}) => {
      'claim_id': id,
      'pnr_code': 'S958PC',
      'kind': kind,
      'status': status,
      'amount': kind == 'REFUND' ? null : 600.0,
      'currency': kind == 'REFUND' ? null : 'EUR',
      'basis': 'EU261 Art. 5(1)(c), Art. 7(1)',
      'reason': status == 'REJECTED' ? 'Weather on the day' : null,
      'payout_reference': status == 'PAID' ? 'BANK-0042' : null,
      'passenger': {'first_name': 'Grace', 'last_name': 'Otieno'},
    };

Map<String, dynamic> _trip({
  String status = 'REACCOMMODATED',
  List<Map<String, dynamic>> entitlements = const [_cash],
  List<Map<String, dynamic>> claims = const [],
  List<Map<String, dynamic>> cases = const [],
  Map<String, dynamic> original = const {},
  Map<String, dynamic>? current,
  bool refundable = false,
}) =>
    {
      'pnr_code': 'S958PC',
      'booking': {
        'pnr_code': 'S958PC',
        'booking_status': status,
        'passenger': {'first_name': 'Grace', 'last_name': 'Otieno', 'rewards_tier': 'BLUE'},
        'original_flight': {
          'flight_id': 'o-1', 'flight_number': 'KQ116', 'origin': 'AMS', 'destination': 'NBO',
          'departure_local': '2026-12-01T10:00+01:00', 'arrival_local': '2026-12-01T19:30+03:00',
          'status': 'CANCELLED', 'disruption_reason': 'TECHNICAL', ...original,
        },
        'current_flight': current,
        'seat_number': '24A',
        'cabin_class': 'ECONOMY',
        'refundable': refundable,
        'legs': [],
        'final_destination': 'NBO',
      },
      'alternatives': [],
      'entitlements': {
        'decision': {'regulation': 'EU261', 'entitlements': entitlements, 'notes': []},
        'vouchers': [],
      },
      'claims': claims,
      'cases': cases,
      'suggestions': [],
      'cities': {'AMS': 'Amsterdam', 'NBO': 'Nairobi'},
    }; // fmt: skip

class _Backend {
  _Backend(this.trip);
  Map<String, dynamic> trip;
  final posts = <String, Map<String, dynamic>?>{};

  http.Client get client => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST') posts[path] = req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>;
        switch (path) {
          case '/api/trip':
            return http.Response(jsonEncode(trip), 200);
          case '/api/compensation/claim':
            return http.Response(jsonEncode(_claim()), 201);
          case '/api/booking/cancel':
            trip = _trip(status: 'CANCELLED', claims: [_claim(kind: 'REFUND', id: 9)]);
            return http.Response(jsonEncode({'success': true, 'message': 'Your booking is cancelled.'}), 200);
          case '/api/staff/claims':
            return http.Response(
                jsonEncode({'claims': [_claim(), _claim(status: 'APPROVED', id: 8), _claim(status: 'PAID', id: 6)]}),
                200);
        }
        final m = RegExp(r'^/api/staff/claims/(\d+)/(approve|reject|pay)$').firstMatch(path);
        if (m != null) {
          final next = {'approve': 'APPROVED', 'reject': 'REJECTED', 'pay': 'PAID'}[m.group(2)]!;
          return http.Response(jsonEncode(_claim(status: next, id: int.parse(m.group(1)!))), 200);
        }
        return http.Response('{}', 404);
      });
}

Future<TripStore> _pump(WidgetTester tester, _Backend backend, Widget Function(TripStore) home) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(500, 1400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = Session(api: KestrelApi(client: backend.client))
    ..api.token = 't'
    ..api.staffKey = 'k'
    ..staffName = 'Asha';
  final store = TripStore(session.api);
  await store.refresh();
  await tester.pumpWidget(SessionScope(
    session: session,
    child: ShellScope(
      shell: ShellController(),
      child: PublicScope(
        public: PublicController(),
        child: TripScope(
          store: store,
          child: MaterialApp(theme: kestrelTheme(), home: Scaffold(body: home(store))),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return store;
}

Widget _panel(TripStore s) => ListenableBuilder(
    listenable: s, builder: (_, __) => SingleChildScrollView(child: CompensationPanel(trip: s.trip!)));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Vouchers: the amount and rule, then a claim and its status', (tester) async {
    final backend = _Backend(_trip());
    await _pump(tester, backend, _panel);
    expect(find.text('EUR 600'), findsOneWidget);
    expect(find.text('Rule: EU261 Art. 5(1)(c), Art. 7(1)'), findsOneWidget);
    backend.trip = _trip(claims: [_claim()]);
    await _tap(tester, find.text('Claim compensation'));
    expect(backend.posts.containsKey('/api/compensation/claim'), isTrue);
    expect(find.text('Claim compensation'), findsNothing);
    expect(find.text('CLAIMED'), findsOneWidget);
    expect(find.textContaining('Waiting for review'), findsOneWidget);
  });

  testWidgets('no compensation from the rules: no claim is offered', (tester) async {
    await _pump(tester, _Backend(_trip(entitlements: [])), _panel);
    expect(find.text('Claim compensation'), findsNothing);
    expect(find.textContaining('EUR'), findsNothing);
  });

  testWidgets('still disrupted: the claim waits for the new flight', (tester) async {
    await _pump(tester, _Backend(_trip(status: 'DISRUPTED')), _panel);
    expect(find.text('Claim compensation'), findsNothing);
    expect(find.textContaining('once you\'ve chosen your new flight'), findsOneWidget);
  });

  testWidgets('a rejected claim shows its reason, a paid one its reference', (tester) async {
    await _pump(tester, _Backend(_trip()), (_) => Column(children: [
          ClaimCard(claim: Claim(_claim(status: 'REJECTED'))),
          ClaimCard(claim: Claim(_claim(status: 'PAID'))),
        ]));
    expect(find.text('Not approved: Weather on the day.'), findsOneWidget);
    expect(find.text('Paid. Payment reference BANK-0042.'), findsOneWidget);
  });

  testWidgets('My trip: cancel and refund asks first, then shows the refund request', (tester) async {
    final backend = _Backend(_trip(status: 'DISRUPTED', entitlements: [], refundable: true));
    await _pump(tester, backend, (_) => TripScreen(onAsk: (_, {intent}) {}));
    await _tap(tester, find.text('Cancel and request a refund'));
    await _tap(tester, find.text('Keep my booking'));
    expect(backend.posts.containsKey('/api/booking/cancel'), isFalse);

    await _tap(tester, find.text('Cancel and request a refund'));
    await _tap(tester, find.text('Cancel and refund'));
    expect(backend.posts.containsKey('/api/booking/cancel'), isTrue);
    expect(find.textContaining('Your booking is cancelled and your refund has been requested'), findsOneWidget);
    expect(find.text('Refund request'), findsOneWidget);
    expect(find.text('Cancel and request a refund'), findsNothing);
  });

  testWidgets('My trip: a delay keeps the seat and offers no free rebooking', (tester) async {
    final backend = _Backend(_trip(status: 'CONFIRMED', entitlements: [], original: {
      'status': 'DELAYED',
      'departure_local': '2026-12-01T12:30+01:00',
      'scheduled_departure_local': '2026-12-01T10:00+01:00',
      'delay_minutes': 150,
    }));
    await _pump(tester, backend, (_) => TripScreen(onAsk: (_, {intent}) {}));
    expect(find.text('Delayed by 2 h 30 min'), findsOneWidget);
    expect(find.textContaining('instead of 10:00'), findsOneWidget);
    expect(find.textContaining('doesn\'t come with a free change of flight'), findsOneWidget);
    expect(find.text('Choose this flight'), findsNothing);
  });

  testWidgets('My trip: no seats left says a case is open', (tester) async {
    final backend = _Backend(_trip(status: 'DISRUPTED', entitlements: [], cases: [
      {'case_id': 3, 'pnr_code': 'S958PC', 'trigger': 'NO_ALTERNATIVES', 'status': 'OPEN'},
    ]));
    await _pump(tester, backend, (_) => TripScreen(onAsk: (_, {intent}) {}));
    expect(find.text('No seats left'), findsOneWidget);
    expect(find.textContaining('We\'ve opened a case'), findsOneWidget);
    expect(find.text('Talk to a person'), findsNothing);
  });

  testWidgets('My trip: a rebooked flight cancelled too is a second disruption', (tester) async {
    final backend = _Backend(_trip(status: 'DISRUPTED', entitlements: [], current: {
      'flight_id': 'c-1', 'flight_number': 'KQ118', 'departure_local': '2026-12-02T10:00+01:00',
    }));
    await _pump(tester, backend, (_) => TripScreen(onAsk: (_, {intent}) {}));
    expect(find.textContaining('Your new flight was cancelled too'), findsOneWidget);
  });

  testWidgets('Staff: approve, reject with a reason, and mark paid with a reference', (tester) async {
    final backend = _Backend(_trip());
    await _pump(tester, backend, (_) => const StaffClaimsView());
    expect(find.textContaining('#7 · S958PC · Grace Otieno'), findsOneWidget);
    expect(find.textContaining('#6'), findsNothing); // paid: not on the to-do list

    await _tap(tester, find.text('Approve'));
    expect(backend.posts['/api/staff/claims/7/approve'], {'by': 'Asha'});
    expect(find.text('APPROVED'), findsNWidgets(2));

    await _tap(tester, find.text('Mark paid').first);
    await tester.enterText(find.byKey(const ValueKey('claim-text')), 'BANK-0042');
    await _tap(tester, find.text('Save'));
    expect(backend.posts.values.whereType<Map>().any((b) => b['payout_reference'] == 'BANK-0042'), isTrue);
  });

  testWidgets('Staff: a rejection needs a reason', (tester) async {
    final backend = _Backend(_trip());
    await _pump(tester, backend, (_) => const StaffClaimsView());
    await _tap(tester, find.text('Reject'));
    await _tap(tester, find.text('Save')); // empty: the dialog stays
    expect(backend.posts.containsKey('/api/staff/claims/7/reject'), isFalse);
    await tester.enterText(find.byKey(const ValueKey('claim-text')), 'Weather');
    await _tap(tester, find.text('Save'));
    expect(backend.posts['/api/staff/claims/7/reject'], {'by': 'Asha', 'reason': 'Weather'});
  });
}
