import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kestrel_app/api/kestrel_api.dart';
import 'package:kestrel_app/auth/account_auth.dart';
import 'package:kestrel_app/format.dart';
import 'package:kestrel_app/main.dart';
import 'package:kestrel_app/api/models.dart';
import 'package:kestrel_app/calendar.dart';
import 'package:kestrel_app/state/recommend.dart';
import 'package:kestrel_app/state/session.dart';
import 'package:kestrel_app/state/trip.dart';
import 'package:kestrel_app/theme.dart';
import 'package:kestrel_app/widgets/cards.dart';
import 'package:kestrel_app/widgets/common.dart';
import 'package:kestrel_app/widgets/google_logo.dart';
import 'package:kestrel_app/widgets/otp_boxes.dart';
import 'package:kestrel_app/widgets/public.dart';
import 'package:kestrel_app/widgets/shell.dart';
import 'package:kestrel_app/widgets/skeleton.dart';

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

Map<String, dynamic> _flight(String id, String number, String dep, String arr, int seats) => {
      'flight_id': id,
      'flight_number': number,
      'origin': 'NBO',
      'destination': 'MBA',
      'departure_local': dep,
      'arrival_local': arr,
      'cabin_class': 'BUSINESS',
      'available_seats': seats,
      'aircraft_type': 'B737-800',
    };

/// GET /api/flights/alternatives.
final _alternatives = {
  'alternatives': [
    _flight('f-2', 'KQ102', '2026-10-11T19:00+03:00', '2026-10-11T20:00+03:00', 4),
    _flight('f-3', 'KQ104', '2026-10-12T07:10+03:00', '2026-10-12T08:10+03:00', 2),
  ],
};

/// GET /api/entitlements before rebooking: the decision, no vouchers yet.
final _entitlements = {
  'decision': {
    'regulation': null,
    'entitlements': [
      {
        'entitlement_type': 'MEAL',
        'label': 'Meal voucher',
        'status': 'ELIGIBLE',
        'explanation': 'You are waiting more than two hours.',
        'basis': 'Kestrel project policy',
        'quantity': 1,
        'amount': 2500,
        'currency': 'KES',
      },
    ],
    'notes': ['No cash compensation: the flight does not depart from the EU or UK.'],
  },
  'vouchers': <Object>[],
};

/// What both sign-in endpoints return with the token (main.py _session_response).
const _signedIn = {
  'access_token': 't',
  'token_type': 'bearer',
  'expires_in': 900,
  'passenger': {'last_name': 'Edwards', 'rewards_tier': 'GOLD', 'pnr_code': 'A27Z99'},
};

/// GET /api/trip: the same pieces, in one body (main.py trip).
Map<String, dynamic> _trip({List<Map<String, dynamic>>? suggestions}) => {
      'pnr_code': 'A27Z99',
      'booking': _me,
      'alternatives': _alternatives['alternatives'],
      'entitlements': _entitlements,
      'cases': <Object>[],
      'cities': {'NBO': 'Nairobi', 'MBA': 'Mombasa'},
      'suggestions': suggestions ??
          [
            {'label': 'Find me another flight', 'intent': 'alternatives'},
            {'label': 'What am I entitled to?', 'intent': 'entitlements'},
            {'label': 'Can I get a refund instead?', 'message': 'Can I get a refund instead?'},
          ],
    };

/// [_me] after a rebooking onto KQ102.
final _rebookedMe = {
  ..._me,
  'booking_status': 'REACCOMMODATED',
  'seat_number': '3C',
  'current_flight': {
    'flight_id': 'f-102',
    'flight_number': 'KQ102',
    'origin': 'NBO',
    'destination': 'MBA',
    'departure_time': '2026-10-11T16:00:00+00:00',
    'arrival_time': '2026-10-11T17:00:00+00:00',
    'departure_local': '2026-10-11T19:00+03:00',
    'arrival_local': '2026-10-11T20:00+03:00',
  },
};

/// One case as GET /api/staff/cases returns it (handoff.py case_to_dict).
Map<String, dynamic> _case({String status = 'OPEN', String? by, String? note}) => {
      'case_id': 41,
      'pnr_code': 'M4T2QD',
      'trigger': 'LOW_SIMILARITY',
      'booking_status': 'DISRUPTED',
      'question': 'Can I bring my pet parrot in the cabin?',
      'top_similarity': 0.61,
      'similarity_scores': [
        {'ref': 'Art. 8.3', 'similarity': 0.61, 'text': '...'},
      ],
      'summary': 'Best clause was below the threshold, so the assistant handed over.',
      'status': status,
      'created_at': '2026-10-17T09:12:00+00:00',
      'resolved_at': status == 'RESOLVED' ? '2026-10-17T09:30:00+00:00' : null,
      'resolved_by': by,
      'resolution_note': note,
    };

/// A queue with long case numbers and both booking states, for the table
/// layout checks.
List<Map<String, dynamic>> _busyQueue() => [
      {
        ..._case(),
        'case_id': 20419,
        'pnr_code': 'A27Z99',
        'trigger': 'STEP_LIMIT',
        'booking_status': 'REACCOMMODATED',
      },
      {..._case(), 'case_id': 20431, 'pnr_code': 'R7HB2L', 'trigger': 'NO_ALTERNATIVES'},
      {..._case(status: 'RESOLVED', by: 'STAFF:Achieng', note: 'Rebooked by phone.'), 'case_id': 20398},
    ];

/// Supabase Auth, faked: Google answers at once (no redirect in a test), and
/// [code] is the code "emailed" to every address.
class _FakeAuth implements AccountAuth {
  _FakeAuth({this.pending, this.sendError});

  @override
  bool get available => true;

  /// Supabase starting in the background; ready unless a test says otherwise.
  final connecting = ValueNotifier(true);

  @override
  ValueListenable<bool> get ready => connecting;

  /// A Google sign-in that came back while the app loaded.
  AccountIdentity? pending;

  /// Sending a code fails with this (e.g. rate limited).
  AccountAuthException? sendError;

  static const code = '123456';
  static const accessToken = 'supabase-access-token-for-tests';

  /// The code has passed its 10 minutes.
  bool expired = false;

  /// While set, checking a code waits on it (to look at the page meanwhile).
  Completer<void>? hold;
  final sent = <String>[];

  /// Every code checked, in order.
  final codes = <String>[];
  var signedOut = false;

  @override
  Future<AccountIdentity?> signInWithGoogle({String? redirectTo}) async =>
      const AccountIdentity(accessToken: accessToken, email: 'steven.a@example.com', provider: 'google');

  @override
  Future<void> sendEmailCode(String email) async {
    if (sendError != null) throw sendError!;
    sent.add(email);
  }

  @override
  Future<AccountIdentity> verifyEmailCode({required String email, required String code}) async {
    codes.add(code);
    if (hold != null) await hold!.future;
    if (expired) throw const AccountAuthException(AccountAuthError.expiredCode, 'Token has expired or is invalid');
    if (code != _FakeAuth.code) {
      throw const AccountAuthException(AccountAuthError.invalidCode, 'Token has expired or is invalid');
    }
    return AccountIdentity(accessToken: accessToken, email: email, provider: 'email');
  }

  @override
  AccountIdentity? takePendingIdentity() {
    final p = pending;
    pending = null;
    return p;
  }

  @override
  String? takePendingError() => null;

  @override
  Future<void> signOut() async => signedOut = true;
}

/// A booking under the account's email, as POST /api/auth/account offers it.
const _suggestion = {
  'pnr_code': 'A27Z99',
  'origin': 'NBO',
  'destination': 'MBA',
  'departure_date': '2026-10-11',
  'booking_status': 'DISRUPTED',
};

/// The REST tier, faked. Records the staff resolve request it receives.
class _Backend {
  _Backend({
    this.acceptLogin = true,
    List<Map<String, dynamic>>? staffQueue,
    this.expireSession = false,
    this.rebookStatus,
    this.chatStatus,
    this.accountLinked = true,
  }) : staffQueue = staffQueue ?? [_case()];
  final bool acceptLogin;
  final List<Map<String, dynamic>> staffQueue;

  /// The Supabase account is already linked to a booking. If not, POST
  /// /api/auth/account answers link_required until a booking is given.
  bool accountLinked;

  /// What POST /api/auth/account says about the link: false when a
  /// reference and surname opened someone else's booking (issue #1).
  bool linksAccount = true;

  /// The bodies DELETE /api/auth/account/link received.
  final unlinkRequests = <Map<String, dynamic>>[];

  /// The bodies POST /api/auth/account received.
  final accountRequests = <Map<String, dynamic>>[];

  /// Every path requested, in order.
  final paths = <String>[];

  /// While set, GET /api/trip waits on it (to look at the page meanwhile).
  Completer<void>? holdTrip;

  /// The trip's suggested next steps, when a test sets them.
  List<Map<String, dynamic>>? tripSuggestions;

  /// The booking's saved conversation (GET /api/chat/history).
  List<Map<String, dynamic>> historyTurns = [];
  int historyDeletes = 0;

  int get tripCalls => paths.where((p) => p == '/api/trip').length;

  /// The bodies the assistant received (POST /api/chat/stream).
  final chatRequests = <Map<String, dynamic>>[];

  /// The token stops working right after sign-in (401 on the next call).
  final bool expireSession;

  /// Status for POST /api/reaccommodate (409 = the seat went first).
  final int? rebookStatus;

  /// POST /api/reaccommodate succeeded: GET /api/trip now returns the new flight.
  bool rebooked = false;

  /// Status for the agent's POST /api/chat (503 = the assistant is busy).
  final int? chatStatus;
  static const staffKey = 'desk-key';

  /// The `status` of every GET /api/staff/cases.
  final staffStatuses = <String?>[];
  Map<String, dynamic>? resolveBody;

  http.Client get client => MockClient((req) async {
        final path = req.url.path;
        paths.add(path);
        http.Response json(Object body, [int code = 200]) => http.Response(jsonEncode(body), code);
        if (path.startsWith('/api/staff/')) {
          if (req.headers['X-Staff-Key'] != staffKey) return json({'detail': 'Invalid staff key.'}, 401);
          if (path == '/api/staff/cases') {
            staffStatuses.add(req.url.queryParameters['status']);
            final want = req.url.queryParameters['status'];
            final cases = staffQueue.where((c) => want == 'ALL' || c['status'] == want).toList();
            return json({'count': cases.length, 'cases': cases});
          }
          if (path == '/api/staff/cases/41/resolve') {
            resolveBody = jsonDecode(req.body) as Map<String, dynamic>;
            return json(_case(status: 'RESOLVED', by: 'STAFF:${resolveBody!['resolved_by']}', note: resolveBody!['note'] as String));
          }
        }
        if (path == '/api/auth/session') {
          return acceptLogin
              ? json(_signedIn)
              : json({'detail': 'No booking matches that PNR and surname.'}, 401);
        }
        if (path == '/api/auth/account/link' && req.method == 'DELETE') {
          unlinkRequests.add(jsonDecode(req.body) as Map<String, dynamic>);
          return json({'unlinked': true});
        }
        if (path == '/api/auth/account') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          accountRequests.add(body);
          if (body['access_token'] != _FakeAuth.accessToken) return json({'detail': 'Sign-in is not valid.'}, 401);
          if (body['pnr_code'] != null) accountLinked = true;
          return accountLinked
              ? json({..._signedIn, 'linked': linksAccount})
              : json({'link_required': true, 'suggestions': [_suggestion], 'cities': {'NBO': 'Nairobi', 'MBA': 'Mombasa'}});
        }
        if (req.headers['Authorization'] != 'Bearer t') return json({'detail': 'Not signed in.'}, 401);
        if (expireSession && path == '/api/trip') return json({'detail': 'Session expired.'}, 401);
        if (path == '/api/trip' && holdTrip != null) await holdTrip!.future;
        if (rebookStatus != null && path == '/api/reaccommodate') {
          return json({'detail': 'That seat is no longer available.'}, rebookStatus!);
        }
        if (path == '/api/reaccommodate') {
          rebooked = true;
          return json({'success': true, 'assigned_seat': '3C', 'message': 'ok', 'booking': _rebookedMe, 'entitlements': null});
        }
        final turn = path == '/api/chat' || path == '/api/chat/stream';
        if (turn) chatRequests.add(jsonDecode(req.body) as Map<String, dynamic>);
        if (chatStatus != null && turn) {
          return json({'detail': 'The assistant is busy.'}, chatStatus!);
        }
        if (path == '/api/chat/history') {
          if (req.method == 'DELETE') {
            historyDeletes++;
            final n = historyTurns.length;
            historyTurns = [];
            return json({'pnr_code': 'A27Z99', 'deleted': n});
          }
          return json({'pnr_code': 'A27Z99', 'turns': historyTurns});
        }
        if (path == '/api/chat/stream') {
          return http.Response(
              _sse([
                ('status', {'text': 'Checking what you\u2019re entitled to\u2026'}),
                ('delta', {'text': 'You get a meal voucher.'}),
                ('done', {
                  'reply': 'You get a meal voucher.',
                  'events': <Object>[],
                  'suggestions': <Object>[],
                  'timing': {'total_ms': 420, 'first_token_ms': 400},
                }),
              ]),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'});
        }
        return switch (path) {
          '/api/me' => json(_me),
          '/api/trip' => json(rebooked
              ? {..._trip(suggestions: tripSuggestions), 'booking': _rebookedMe}
              : _trip(suggestions: tripSuggestions)),
          '/api/flights/alternatives' => json(_alternatives),
          '/api/entitlements' => json(_entitlements),
          '/api/handoff' => json({'pnr_code': 'A27Z99', 'cases': <Object>[]}),
          _ => http.Response('{}', 404),
        };
      });
}

/// Screen sizes the client is built for (logical pixels): a common Android
/// phone and a laptop browser window. The default 800 x 600 test window is
/// neither, and is shorter than the sign-in form.
const phone = Size(412, 915);
const laptop = Size(1440, 900);

/// Builds the app as a browser would see it. Account sign-in (Supabase) is
/// the fake [auth], set up unless a test says otherwise.
/// Server-Sent Events, as POST /api/chat/stream writes them.
String _sse(List<(String, Map<String, dynamic>)> events) =>
    events.map((e) => 'event: ${e.$1}\ndata: ${jsonEncode(e.$2)}\n\n').join();

Future<void> _pump(WidgetTester tester, http.Client client,
    {Size screen = phone,
    AccountAuth? auth,
    Duration tripMaxAge = const Duration(seconds: 60),
    http.Client? streamClient}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = screen;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(KestrelApp(
      session: Session(
          api: KestrelApi(client: client, streamClient: streamClient),
          auth: auth ?? _FakeAuth(),
          tripMaxAge: tripMaxAge)));
  await tester.pumpAndSettle();
}

Finder get _otpFields => find.descendant(of: find.byType(OtpBoxes), matching: find.byType(TextField));

String _otpDigits(WidgetTester tester) =>
    tester.widgetList<TextField>(_otpFields).map((f) => f.controller!.text).join();

/// Home → Sign in → email → "Send verification code".
Future<void> _sendCode(WidgetTester tester, {String email = 'steven.a@example.com'}) async {
  await _tapText(tester, 'Sign in');
  await tester.enterText(find.byType(TextFormField), email);
  await tester.tap(find.text('Send verification code'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Types a whole code, as pasting or the one-time-code autofill does.
Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.enterText(_otpFields.first, code);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Scrolls a button into view, as a person would, then taps it.
Future<void> _tapText(WidgetTester tester, String text) async {
  final button = find.text(text);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Signs in as a guest with the booking-reference form on Home.
Future<void> _signIn(WidgetTester tester,
    {Size screen = phone, _Backend? backend, Duration tripMaxAge = const Duration(seconds: 60)}) async {
  await _pump(tester, (backend ?? _Backend()).client, screen: screen, tripMaxAge: tripMaxAge);
  await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
  await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
  await _tap(tester, find.byKey(GuestBookingForm.submitKey));
}

/// Home → Sign in → "Disruption desk staff sign in here".
Future<void> _toStaffForm(WidgetTester tester) async {
  await _tapText(tester, 'Sign in');
  await _tapText(tester, 'Disruption desk staff sign in here');
}

void main() {
  group('format', () {
    test('local times are shown as written, not converted', () {
      expect(hhmm('2026-10-11T16:21+03:00'), '16:21');
      expect(dayLabel('2026-10-11T16:21+03:00'), 'Sun 11 Oct');
      expect(dayOffset('2026-10-11T22:45+03:00', '2026-10-12T06:10+02:00'), '+1 day');
      expect(duration('2026-10-11T22:45+03:00', '2026-10-12T06:10+02:00'), '8h 25m');
      expect(money(2500, 'KES'), 'KES 2,500');
    });

    test('airport names come from the server (kestrel/airports.py)', () {
      learnCities({'ZZZ': 'Testville'});
      expect(city('ZZZ'), 'Testville');
      expect(city('QQQ'), 'QQQ'); // no name yet: the code
    });

    test('assistant bubbles drop Markdown bold markers', () {
      expect(ChatBubble.plain('Seat **20C** on __KQ116__'), 'Seat 20C on KQ116');
      expect(ChatBubble.plain('2 * 3 = 6'), '2 * 3 = 6');
    });

    test('case times read as "how long ago"', () {
      final now = DateTime.parse('2026-10-17T10:00:00Z');
      expect(since('2026-10-17T09:55:00Z', now: now), '5 min ago');
      expect(since('2026-10-17T07:00:00Z', now: now), '3 h ago');
      // Older cases: the table column keeps to the day; the panel adds the time.
      expect(since('2026-10-15T12:00:00Z', now: now, compact: true), 'Thu 15 Oct');
      expect(since('2026-10-15T12:00:00Z', now: now), startsWith('Thu 15 Oct, '));
      expect(initials('Grace', 'Edwards'), 'GE');
      expect(initials('', ''), '?');
    });
  });

  testWidgets('sign-in validates the PNR before calling the API', (tester) async {
    var calls = 0;
    await _pump(tester, MockClient((_) async {
      calls++;
      return http.Response('{}', 500);
    }));
    await _tap(tester, find.byKey(GuestBookingForm.submitKey));
    expect(find.text('Enter your 6-character booking reference.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('wrong surname shows the server message', (tester) async {
    await _pump(tester, _Backend(acceptLogin: false).client);
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Wrong');
    await _tap(tester, find.byKey(GuestBookingForm.submitKey));
    expect(find.text('No booking matches that PNR and surname.'), findsOneWidget);
  });

  testWidgets('sign-in opens My trip: the ticket, flights to move to, and the tab bar', (tester) async {
    await _signIn(tester);

    expect(find.text('Hi, Grace'), findsOneWidget);
    expect(find.text('KESTREL RECOMMENDS'), findsOneWidget); // first, at the top
    expect(find.textContaining('KQ100'), findsWidgets); // the ticket
    // The page builds as it scrolls, so scroll down to the flights.
    await tester.dragUntilVisible(
        find.text('Flights from Nairobi'), find.byType(ListView).first, const Offset(0, -250));
    expect(find.text('Cancelled because of weather.'), findsOneWidget);
    await tester.dragUntilVisible(
        find.text('EARLIEST ARRIVAL'), find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('EARLIEST ARRIVAL'), findsOneWidget);
    expect(find.textContaining('KQ102'), findsWidgets); // first alternative
    expect(find.byType(NavigationBar), findsOneWidget); // phone layout
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Assistant tab greets the passenger from the booking', (tester) async {
    await _signIn(tester);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget); // the composer
    expect(find.textContaining('Hello Grace'), findsOneWidget);
    expect(find.textContaining('because of weather'), findsOneWidget);
    expect(find.text('Talk to a person'), findsOneWidget); // quick reply
    expect(find.byTooltip('Speak your question'), findsOneWidget);
  });

  testWidgets('in a laptop browser the app has a sidebar instead of the tab bar', (tester) async {
    await _signIn(tester, screen: laptop);

    expect(find.byType(NavigationBar), findsNothing);
    for (final label in ['My trip', 'Assistant', 'Flights', 'Vouchers', 'Help']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Need a person?'), findsOneWidget);
    expect(find.text('Your recovery'), findsOneWidget); // second column
    expect(find.text('Grace Edwards'), findsWidgets); // top bar and ticket
    expect(tester.takeException(), isNull); // no overflow at this size
  });

  testWidgets('the chat stays at a readable width on a wide screen', (tester) async {
    await _signIn(tester, screen: const Size(1920, 1080));
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    final composer = tester.getSize(find.byType(TextField));
    expect(composer.width, lessThan(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('staff sign in to the desk and resolve a case with a note', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend.client, screen: laptop);
    await _toStaffForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'Wanjiru');
    await tester.enterText(find.byType(TextFormField).at(1), 'desk-key');
    await _tapText(tester, 'Open the desk');

    expect(find.text('Open cases'), findsWidgets); // sidebar and heading
    // Open cases on their own (newest first), never "ALL" cut off at 200.
    expect(backend.staffStatuses, containsAll(['OPEN', 'RESOLVED']));
    expect(backend.staffStatuses, isNot(contains('ALL')));
    expect(find.text('Case #41'), findsWidgets); // table row and detail panel
    expect(find.text('Question outside the policy'), findsWidgets);
    expect(find.text('Can I bring my pet parrot in the cabin?'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'Called the passenger and explained the pet policy.');
    await _tapText(tester, 'Resolve case');

    expect(backend.resolveBody, {'resolved_by': 'Wanjiru', 'note': 'Called the passenger and explained the pet policy.'});
    expect(find.textContaining('Resolved by Wanjiru'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> openDesk(WidgetTester tester, Size screen) async {
    await _pump(tester, _Backend(staffQueue: _busyQueue()).client, screen: screen);
    await _toStaffForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'Wanjiru');
    await tester.enterText(find.byType(TextFormField).at(1), 'desk-key');
    await _tapText(tester, 'Open the desk');
  }

  /// True when a Text shows all of its words (no ellipsis, nothing clipped).
  bool shownInFull(WidgetTester tester, Finder f) =>
      f.evaluate().isNotEmpty &&
      f.evaluate().every((e) => !(e.renderObject! as RenderParagraph).didExceedMaxLines);

  testWidgets('staff desk at 1280 x 800: status chips and case numbers show in full', (tester) async {
    await openDesk(tester, const Size(1280, 800));

    expect(tester.takeException(), isNull); // no overflow anywhere
    for (final chip in ['CONFIRMED', 'CANCELLED', 'OPEN']) {
      expect(shownInFull(tester, find.text(chip)), isTrue, reason: '$chip chip is cut short');
    }
  });

  testWidgets('staff desk table: columns fit, and Opened gives way to the case panel below 1360 px',
      (tester) async {
    // The test font draws every glyph a full em wide, about 1.6 times wider
    // than Inter; scaling the text down approximates the real metrics, so
    // this exercises the table layout a laptop actually gets.
    tester.platformDispatcher.textScaleFactorTestValue = 0.62;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openDesk(tester, const Size(1280, 800));

    expect(find.text('REASON'), findsOneWidget); // the table, not cards
    expect(find.text('OPENED'), findsNothing); // panel open below 1360 px
    expect(find.text('Case #20419'), findsWidgets);
    expect(shownInFull(tester, find.text('Case #20419')), isTrue);
    for (final chip in ['CONFIRMED', 'CANCELLED']) {
      expect(shownInFull(tester, find.text(chip)), isTrue, reason: '$chip chip is cut short');
    }
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.text('OPENED'), findsOneWidget); // room for it again
    expect(shownInFull(tester, find.text('CONFIRMED')), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Confirm opens inside the layout and Back returns to My trip (laptop)', (tester) async {
    await _signIn(tester, screen: laptop);
    final choose = find.text('Choose').first; // the earliest-arrival flight
    await tester.ensureVisible(choose);
    await tester.pumpAndSettle();
    await tester.tap(choose);
    await tester.pumpAndSettle();

    expect(find.text('Confirm your new flight'), findsOneWidget);
    expect(find.byType(TopBar), findsOneWidget); // still inside the layout
    expect(find.text('Need a person?'), findsOneWidget); // sidebar too

    await _tapText(tester, 'Back');
    expect(find.text('Confirm your new flight'), findsNothing);
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  testWidgets('Confirm keeps the phone tab bar, and the system Back button closes it', (tester) async {
    await _signIn(tester);
    await tester.dragUntilVisible(
        find.text('KQ102 · Sun 11 Oct'), find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KQ102 · Sun 11 Oct'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm your new flight'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.binding.handlePopRoute(); // Android back / browser back gesture
    await tester.pumpAndSettle();
    expect(find.text('Confirm your new flight'), findsNothing);
    // Still signed in, back on My trip where the passenger left it.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('KQ102 · Sun 11 Oct'), findsOneWidget);
  });

  testWidgets('brand line, app title and disclaimer', (tester) async {
    await _pump(tester, _Backend().client, screen: laptop);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Kestrel — disruption assistant');
    expect(find.text('KENYA AIRWAYS'), findsNothing);
    expect(find.textContaining(disclaimer), findsOneWidget); // Home footer

    await _tapText(tester, 'Sign in');
    expect(find.text(disclaimer), findsOneWidget); // sign-in page, on the brand panel

    await _tap(tester, find.text('Continue as guest'));
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
    await _tap(tester, find.byKey(GuestBookingForm.submitKey));
    expect(find.text('Disruption assistant'), findsOneWidget); // sidebar brand line
    expect(find.text(disclaimer), findsOneWidget); // bottom of the sidebar
  });

  testWidgets('a wrong staff key is reported on the sign-in form', (tester) async {
    await _pump(tester, _Backend().client);
    await _toStaffForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'Wanjiru');
    await tester.enterText(find.byType(TextFormField).at(1), 'wrong');
    await _tapText(tester, 'Open the desk');
    expect(find.text('Invalid staff key.'), findsOneWidget);
  });

  testWidgets('touch targets meet the 48 dp minimum on Home and the sign-in page', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _Backend().client);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await _tapText(tester, 'Sign in');
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    semantics.dispose();
  });

  // -- Phase 2: public Home, sign-in, Help, system states ----------------------

  for (final (name, size) in [('laptop', const Size(1440, 900)), ('phone', const Size(412, 915))]) {
    testWidgets('Home renders without overflow ($name)', (tester) async {
      await _pump(tester, _Backend().client, screen: size);
      expect(find.textContaining('Cancelled flight.'), findsOneWidget);
      expect(find.text('Every answer shows its source'), findsOneWidget);
      expect(find.text('Questions passengers ask'), findsOneWidget);
      expect(find.byKey(GuestBookingForm.submitKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  // UI UX Pro Max pre-delivery checks: small phone, landscape, larger text.
  for (final (name, size, scale) in [
    ('375 px phone', const Size(375, 667), 1.0),
    ('phone landscape', const Size(844, 390), 1.0),
    ('larger text', const Size(412, 915), 1.5),
  ]) {
    testWidgets('Home and sign-in hold up: $name', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, _Backend().client, screen: size);
      expect(tester.takeException(), isNull);
      // With little room, "Sign in" lives in the menu.
      if (find.text('Sign in').evaluate().isEmpty) await _tap(tester, find.byTooltip('Menu'));
      await _tapText(tester, 'Sign in');
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the booking form on Home signs a guest in', (tester) async {
    await _signIn(tester, screen: laptop);
    expect(find.text('Hi, Grace'), findsOneWidget);
    expect(find.text('Need a person?'), findsOneWidget); // the passenger layout
  });

  testWidgets('sign-in page: Google and email, and no Apple', (tester) async {
    await _pump(tester, _Backend().client, screen: laptop);
    await _tapText(tester, 'Sign in');
    expect(find.text('Sign in to Kestrel'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('EMAIL'), findsOneWidget);
    expect(find.text('Send verification code'), findsOneWidget);
    expect(find.text('Disruption desk staff sign in here'), findsOneWidget);
    expect(find.textContaining('Apple'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a valid email reveals six code boxes on the same page', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);

    expect(auth.sent, ['steven.a@example.com']);
    expect(find.text('Sign in to Kestrel'), findsOneWidget); // still the same page
    expect(_otpFields, findsNWidgets(6));
    expect(find.text('Code sent to s••••••@example.com'), findsOneWidget);
    expect(find.textContaining('Resend in'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    expect(tester.widget<TextField>(_otpFields.first).autofillHints, [AutofillHints.oneTimeCode]);
  });

  testWidgets('pasting a 6-digit code fills all six boxes and submits it', (tester) async {
    final auth = _FakeAuth()..hold = Completer<void>();
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);
    await _enterCode(tester, '481234');
    expect(_otpDigits(tester), '481234');
    expect(auth.codes, ['481234']); // the sixth digit submitted it, once
    expect(find.bySemanticsLabel('Verify and sign in, working'), findsOneWidget);
  });

  testWidgets('an invalid email is refused and reveals nothing', (tester) async {
    await _pump(tester, _Backend().client);
    await _tapText(tester, 'Sign in');
    await tester.enterText(find.byType(TextFormField), 'steven.example.com');
    await tester.tap(find.text('Send verification code'));
    await tester.pump();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.byType(OtpBoxes), findsNothing);
    expect(find.textContaining('Code sent'), findsNothing);
  });

  // -- Phase 4: Google and emailed-code sign-in (Supabase, faked) -------------

  testWidgets('Google: a linked account opens My trip', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend.client, screen: laptop);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    expect(backend.accountRequests.single, {'access_token': _FakeAuth.accessToken});
    expect(find.text('Hi, Grace'), findsOneWidget);
    expect(find.text('Need a person?'), findsOneWidget); // the passenger layout
  });

  testWidgets('a linked account can unlink its booking from the account menu', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend.client, screen: laptop);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    await _tap(tester, find.byTooltip('Account'));
    await _tapText(tester, 'Unlink this booking');
    expect(backend.unlinkRequests.single, {'access_token': _FakeAuth.accessToken});
    expect(find.text('Hi, Grace'), findsNothing); // signed out
  });

  testWidgets('a booking opened without a link offers no unlink, and a guest none either', (tester) async {
    final backend = _Backend()..linksAccount = false;
    await _pump(tester, backend.client, screen: laptop);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    await _tap(tester, find.byTooltip('Account'));
    expect(find.text('Sign out'), findsWidgets);
    expect(find.text('Unlink this booking'), findsNothing);
  });

  testWidgets('back from Google in the browser: the app finishes signing in', (tester) async {
    final auth = _FakeAuth(
        pending: const AccountIdentity(
            accessToken: _FakeAuth.accessToken, email: 'steven.a@example.com', provider: 'google'));
    await _pump(tester, _Backend().client, screen: laptop, auth: auth);
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  testWidgets('link_required: Link booking page, then linking the match signs in', (tester) async {
    final backend = _Backend(accountLinked: false);
    await _pump(tester, backend.client, screen: laptop);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');

    expect(find.text('Link your booking'), findsOneWidget);
    expect(find.text('Signed in with Google · steven.a@example.com'), findsOneWidget);
    expect(find.text('A27Z99 · NBO → MBA'), findsOneWidget);
    expect(find.text('Add a different booking'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _tapText(tester, 'Link and continue');
    // The matched booking goes by reference alone: the server checks the email.
    expect(backend.accountRequests.last, {'access_token': _FakeAuth.accessToken, 'pnr_code': 'A27Z99'});
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  // UI UX Pro Max pre-delivery checks for the one new page.
  for (final (name, size, scale) in [
    ('375 px phone', const Size(375, 667), 1.0),
    ('larger text', const Size(412, 915), 1.5),
  ]) {
    testWidgets('Link booking holds up: $name', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      await _pump(tester, _Backend(accountLinked: false).client, screen: size);
      if (find.text('Sign in').evaluate().isEmpty) await _tap(tester, find.byTooltip('Menu'));
      await _tapText(tester, 'Sign in');
      await _tapText(tester, 'Continue with Google');
      expect(find.text('Link your booking'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await _tapText(tester, 'Add a different booking');
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('Link booking: a different booking by reference and surname', (tester) async {
    final backend = _Backend(accountLinked: false);
    await _pump(tester, backend.client);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    await _tapText(tester, 'Add a different booking');
    await tester.enterText(find.byType(TextFormField).at(0), 'r7hb2l');
    await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
    await _tapText(tester, 'Link and continue');
    expect(backend.accountRequests.last,
        {'access_token': _FakeAuth.accessToken, 'pnr_code': 'R7HB2L', 'last_name': 'Edwards'});
    expect(find.byType(NavigationBar), findsOneWidget); // signed in, phone layout
  });

  testWidgets('Link booking: "Skip for now" returns to sign-in as a guest', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, _Backend(accountLinked: false).client, auth: auth);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    await _tapText(tester, 'Skip for now');
    expect(auth.signedOut, isTrue);
    expect(find.text('Find your booking'), findsOneWidget);
  });

  testWidgets('email: send a code, the boxes appear on the same page, the right code signs in', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend.client, screen: laptop);
    await _sendCode(tester);
    expect(find.text('Sign in to Kestrel'), findsOneWidget);
    await _enterCode(tester, _FakeAuth.code);
    await tester.pumpAndSettle();
    expect(backend.accountRequests.single, {'access_token': _FakeAuth.accessToken});
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  testWidgets('a wrong code shows the tries left and clears the boxes', (tester) async {
    await _pump(tester, _Backend().client);
    await _sendCode(tester);
    await _enterCode(tester, '000000');
    expect(find.text('That code isn\'t right. 4 tries left.'), findsOneWidget);
    expect(_otpDigits(tester), '');
    await _enterCode(tester, '000001');
    expect(find.text('That code isn\'t right. 3 tries left.'), findsOneWidget);
  });

  testWidgets('5 wrong codes disable verifying until a new code is sent', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);
    for (var i = 0; i < 5; i++) {
      await _enterCode(tester, '00000$i');
    }
    expect(find.text('Too many wrong codes. Send a new code to try again.'), findsOneWidget);
    expect(tester.widget<OtpBoxes>(find.byType(OtpBoxes)).enabled, isFalse);
    expect(tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'Verify and sign in')).onPressed, isNull);
    expect(auth.codes, hasLength(5));

    // A new code (after the 60-second wait) gives the tries back.
    await tester.pump(const Duration(seconds: 60));
    await _tapText(tester, 'Resend code');
    expect(auth.sent, hasLength(2));
    expect(tester.widget<OtpBoxes>(find.byType(OtpBoxes)).enabled, isTrue);
    expect(find.textContaining('Too many wrong codes'), findsNothing);
  });

  testWidgets('an expired code asks for a new one', (tester) async {
    final auth = _FakeAuth()..expired = true;
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);
    await _enterCode(tester, _FakeAuth.code);
    expect(find.text('This code has expired. Send a new one.'), findsOneWidget);
  });

  testWidgets('Resend is disabled for 60 s, with a countdown, then sends a new code', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);
    expect(find.text('Resend in 1:00'), findsOneWidget);
    expect(find.text('Resend code'), findsNothing);

    await tester.pump(const Duration(seconds: 59));
    expect(find.text('Resend in 0:01'), findsOneWidget);
    expect(find.text('Resend code'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await _tapText(tester, 'Resend code');
    expect(auth.sent, hasLength(2));
    expect(find.text('Resend in 1:00'), findsOneWidget); // the wait starts again
  });

  testWidgets('"Change" returns to an empty email field and drops the code', (tester) async {
    await _pump(tester, _Backend().client);
    await _sendCode(tester);
    await _tapText(tester, 'Change');
    expect(find.byType(OtpBoxes), findsNothing);
    expect(tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text, '');
    expect(find.text('Send verification code'), findsOneWidget);
  });

  testWidgets('too many codes requested: the reason shows under the email field', (tester) async {
    final auth = _FakeAuth(
        sendError: const AccountAuthException(AccountAuthError.rateLimited, 'email rate limit exceeded'));
    await _pump(tester, _Backend().client, auth: auth);
    await _sendCode(tester);
    expect(find.text('Too many codes requested. Try again in a minute.'), findsOneWidget);
    expect(find.byType(OtpBoxes), findsNothing);
  });

  testWidgets('Google and email are hidden when the build has no Supabase settings', (tester) async {
    await _pump(tester, _Backend().client, auth: const UnavailableAccountAuth());
    await _tapText(tester, 'Sign in');
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('Send verification code'), findsNothing);
    expect(find.text('EMAIL'), findsNothing);
    // Guest and staff sign-in remain.
    expect(find.text('Continue as guest'), findsOneWidget);
    expect(find.text('Disruption desk staff sign in here'), findsOneWidget);
  });

  // -- Performance plan, Phase 1: nothing waits for Supabase -----------------

  testWidgets('Google and email show at once and wait, disabled, until Supabase connects', (tester) async {
    final auth = _FakeAuth()..connecting.value = false;
    await _pump(tester, _Backend().client, screen: laptop, auth: auth);
    expect(find.textContaining('Cancelled flight.'), findsOneWidget); // Home did not wait
    await tester.tap(find.text('Sign in').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    OutlinedButton google() => tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('Continue with Google'), matching: find.byType(OutlinedButton)));
    PrimaryButton send() => tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'Send verification code'));
    expect(find.text('Connecting to the sign-in service…'), findsOneWidget);
    expect(google().onPressed, isNull);
    expect(send().onPressed, isNull);
    expect(find.text('Continue as guest'), findsOneWidget); // the booking reference never waits

    auth.connecting.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Connecting to the sign-in service…'), findsNothing);
    expect(google().onPressed, isNotNull);
    expect(send().onPressed, isNotNull);
  });

  test('a deferred sign-in service is ready once connected, and unreachable if it failed to start', () async {
    final ok = DeferredAccountAuth(Future.value(_FakeAuth()));
    expect(ok.ready.value, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(ok.ready.value, isTrue);
    await ok.sendEmailCode('steven.a@example.com');

    final down = DeferredAccountAuth(Future.error(Exception('offline')));
    await expectLater(
      down.sendEmailCode('steven.a@example.com'),
      throwsA(isA<AccountAuthException>().having((e) => e.kind, 'kind', AccountAuthError.unreachable)),
    );
    expect(down.ready.value, isTrue);
  });

  // -- Performance plan, Phase 2: one call for the trip, read from the store ---

  testWidgets('My trip shows skeletons shaped like its cards until the trip arrives', (tester) async {
    final semantics = tester.ensureSemantics();
    final backend = _Backend()..holdTrip = Completer<void>();
    await _pump(tester, backend.client);
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
    await tester.ensureVisible(find.byKey(GuestBookingForm.submitKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GuestBookingForm.submitKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Signed in: the layout is up at once, the trip still on its way.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(TripSkeleton), findsOneWidget);
    expect(find.bySemanticsLabel('Loading your trip'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing); // no spinner
    expect(find.text('Hi, Grace'), findsNothing);

    backend.holdTrip!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TripSkeleton), findsNothing);
    expect(find.text('Hi, Grace'), findsOneWidget);
    expect(backend.tripCalls, 1);
    semantics.dispose();
  });

  testWidgets('every section reads the stored trip: one request for all of them', (tester) async {
    final backend = _Backend();
    await _signIn(tester, screen: laptop, backend: backend);
    for (final section in ['Flights', 'Vouchers', 'Help', 'Assistant', 'My trip']) {
      await tester.tap(find.text(section).first);
      await tester.pump(); // the stored trip, on the first frame
      expect(find.byType(ListSkeleton), findsNothing, reason: section);
      expect(find.byType(TripSkeleton), findsNothing, reason: section);
      await tester.pumpAndSettle();
    }
    expect(find.text('Hi, Grace'), findsOneWidget);
    expect(backend.tripCalls, 1);
    // None of the single endpoints the sections used to call one by one.
    for (final old in ['/api/me', '/api/entitlements', '/api/flights/alternatives', '/api/handoff']) {
      expect(backend.paths, isNot(contains(old)));
    }
  });

  testWidgets('a trip over a minute old is refreshed behind the page, which keeps showing it', (tester) async {
    final backend = _Backend();
    await _signIn(tester, screen: laptop, backend: backend, tripMaxAge: Duration.zero);
    backend.holdTrip = Completer<void>();
    await tester.tap(find.text('Flights').first);
    await tester.pump();
    expect(backend.tripCalls, 2); // refreshing...
    expect(find.text('KQ102'), findsWidgets); // ...while the stored flights show
    expect(find.byType(ListSkeleton), findsNothing);
    backend.holdTrip!.complete();
    await tester.pumpAndSettle();
    expect(find.text('KQ102'), findsWidgets);
  });

  testWidgets('pull to refresh fetches the trip again', (tester) async {
    final backend = _Backend();
    await _signIn(tester, backend: backend);
    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1500);
    await tester.pumpAndSettle();
    expect(backend.tripCalls, 2);
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  test('the trip store shares one request between callers and keeps its data if a refresh fails', () async {
    var calls = 0;
    var fail = false;
    final api = KestrelApi(
      client: MockClient((req) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return fail ? http.Response('{"detail": "down"}', 503) : http.Response(jsonEncode(_trip()), 200);
      }),
    );
    final store = TripStore(api);
    await Future.wait([store.refresh(), store.refresh(), store.refresh()]);
    expect(calls, 1);
    expect(store.trip!.booking.firstName, 'Grace');
    expect(store.trip!.suggestions.first.intent, 'alternatives');

    fail = true;
    await expectLater(store.refresh(), throwsA(isA<ApiException>()));
    expect(store.trip!.booking.firstName, 'Grace'); // still shown
    expect(store.failure, isA<ApiException>());
  });

  testWidgets('signing out signs out of Supabase too', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, _Backend().client, screen: laptop, auth: auth);
    await _tapText(tester, 'Sign in');
    await _tapText(tester, 'Continue with Google');
    await _tapText(tester, 'Sign out');
    expect(auth.signedOut, isTrue);
    expect(find.text('Hi, Grace'), findsNothing);
  });

  testWidgets('Help: the search filters the questions on the page', (tester) async {
    await _pump(tester, _Backend().client, screen: laptop);
    await _tap(tester, find.text('Help').first); // the header link
    expect(find.text('How can we help?'), findsOneWidget);
    expect(find.text('Will I pay to change to another flight?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'voucher');
    await tester.pumpAndSettle();
    expect(find.text('How do I use my meal or hotel voucher?'), findsOneWidget);
    expect(find.text('Will I pay to change to another flight?'), findsNothing);
    expect(find.textContaining('Apple'), findsNothing);
  });

  testWidgets('401: the session-expired page offers both ways back in', (tester) async {
    await _signIn(tester, backend: _Backend(expireSession: true));
    expect(find.text('Your session has expired'), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);

    await _tapText(tester, 'Use booking reference');
    expect(find.text('Find your booking'), findsOneWidget);
  });

  testWidgets('409 on rebooking: "That seat was just taken", then choose another flight', (tester) async {
    await _signIn(tester, screen: laptop, backend: _Backend(rebookStatus: 409));
    await _tap(tester, find.text('Choose').first);
    await _tapText(tester, 'Confirm rebooking');

    expect(find.text('That seat was just taken'), findsOneWidget);
    await _tapText(tester, 'Choose another flight');
    expect(find.text('Confirm your new flight'), findsNothing);
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  // -- Performance plan, Phase 3: streamed replies and instant quick replies --

  testWidgets('a streamed reply: what the assistant is doing, then the words as they arrive', (tester) async {
    final backend = _Backend();
    final body = StreamController<List<int>>();
    final sent = <Map<String, dynamic>>[];
    final stream = MockClient.streaming((req, bodyStream) async {
      sent.add(jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
      return http.StreamedResponse(body.stream, 200, headers: {'content-type': 'text/event-stream'});
    });
    await _pump(tester, backend.client, streamClient: stream);
    await tester.enterText(find.byType(TextFormField).at(0), 'a27z99');
    await tester.enterText(find.byType(TextFormField).at(1), 'Edwards');
    await _tap(tester, find.byKey(GuestBookingForm.submitKey));
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Can I get a refund instead?'));
    await tester.pump();
    expect(find.text('Can I get a refund instead?'), findsWidgets); // the question, sent
    expect(find.byType(ThinkingBubble), findsOneWidget);
    expect(sent.single.containsKey('intent'), isFalse); // the refund question needs the model

    void send(String kind, Map<String, dynamic> data) =>
        body.add(utf8.encode('event: $kind\ndata: ${jsonEncode(data)}\n\n'));
    send('status', {'text': 'Reading the conditions of carriage\u2026'});
    await tester.pump();
    expect(find.text('Reading the conditions of carriage\u2026'), findsOneWidget);

    send('delta', {'text': 'Yes, you can '});
    await tester.pump();
    expect(find.byType(ThinkingBubble), findsNothing);
    expect(find.textContaining('Yes, you can', findRichText: true), findsOneWidget);
    expect(find.byType(TypingCursor), findsOneWidget); // still writing

    send('delta', {'text': 'choose a refund [EU261 Art. 8].'});
    send('done', {
      'reply': 'Yes, you can choose a refund [EU261 Art. 8].',
      'events': <Object>[],
      'suggestions': [
        {'label': 'Talk to a person', 'intent': 'person'},
      ],
      'timing': {'total_ms': 3100, 'first_token_ms': 1200},
    });
    unawaited(body.close());
    await tester.pumpAndSettle();
    expect(find.text('Yes, you can choose a refund [EU261 Art. 8].'), findsOneWidget);
    expect(find.byType(TypingCursor), findsNothing);
    expect(find.text('Answered in 3.1 s'), findsOneWidget);
  });

  testWidgets('quick replies carry their intent; typed text never does', (tester) async {
    final backend = _Backend();
    await _signIn(tester, backend: backend);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();

    await _tapText(tester, 'What am I entitled to?');
    expect(backend.chatRequests.last['intent'], 'entitlements');
    expect(find.text('You get a meal voucher.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'What am I entitled to?');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(backend.chatRequests.last.containsKey('intent'), isFalse);
    expect(backend.chatRequests, hasLength(2));
  });

  // -- Performance plan, Phase 4: intelligent features ------------------------

  test('Kestrel recommends: the earliest arrival, why, and what the passenger is owed', () {
    final now = DateTime(2026, 10, 11, 12);
    final r = recommend(Trip(_trip()), now: now)!;
    expect(r.text,
        'Your best option is KQ102 today at 19:00 \u2014 the earliest arrival in Mombasa, 4 seats left. '
        'You\'re owed a meal voucher.');
    expect(r.question, 'Shall I book it?');
    expect(r.action, RecommendedAction.review);
    expect(r.flight!.id, 'f-2');

    // With the rules' answer for that flight (explain.py "includes").
    final json = _trip();
    (json['alternatives'] as List)[0] = {
      ...(json['alternatives'] as List)[0] as Map<String, dynamic>,
      'departure_local': '2026-10-12T16:31+03:00',
      'badges': ['EARLIEST_ARRIVAL', 'NEXT_DAY_HOTEL'],
      'includes': [
        {'entitlement_type': 'MEAL', 'quantity': 1},
        {'entitlement_type': 'HOTEL', 'quantity': 1},
        {'entitlement_type': 'TRANSPORT', 'quantity': 1},
      ],
    };
    expect(recommend(Trip(json), now: now)!.text,
        contains('KQ102 tomorrow at 16:31 \u2014 the earliest arrival in Mombasa, 4 seats left. '
            'You\'re owed a meal voucher, a hotel night and transfers.'));

    // Nothing to move to: a person.
    final none = _trip()..['alternatives'] = <Object>[];
    expect(recommend(Trip(none))!.action, RecommendedAction.person);
  });

  testWidgets('My trip leads with "Kestrel recommends"; its action opens the flight to confirm', (tester) async {
    await _signIn(tester, screen: laptop);
    expect(find.text('KESTREL RECOMMENDS'), findsOneWidget);
    expect(find.textContaining('Your best option is KQ102'), findsOneWidget);
    await _tapText(tester, 'Review and confirm');
    expect(find.text('Confirm your new flight'), findsOneWidget);
    expect(find.textContaining('KQ102'), findsWidgets);
  });

  testWidgets('the assistant opens with the same recommendation and the flight to choose', (tester) async {
    await _signIn(tester);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your best option is KQ102'), findsOneWidget);
    expect(find.textContaining('Shall I book it?'), findsOneWidget);
    expect(find.byType(FlightOptionCard), findsOneWidget); // under the greeting, with Choose
  });

  testWidgets('a rebooking on the Confirm page rewrites the untouched greeting', (tester) async {
    await _signIn(tester);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Shall I book it?'), findsOneWidget);

    // Rebooked through the REST tier (Confirm), not by the assistant.
    await _tap(tester, find.byType(FlightOptionCard).first);
    await _tapText(tester, 'Confirm rebooking');
    expect(find.text("You're rebooked"), findsOneWidget);

    await _tapText(tester, 'Done');
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Shall I book it?'), findsNothing);
    expect(find.textContaining('booked on KQ102'), findsOneWidget);
  });

  testWidgets('"Why this flight?" opens the reasons the server gave', (tester) async {
    tester.view.physicalSize = laptop;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final flight = Flight({
      ..._flight('f-2', 'KQ102', '2026-10-11T19:00+03:00', '2026-10-11T20:00+03:00', 2),
      'badges': ['EARLIEST_ARRIVAL', 'SAME_DAY', 'ALMOST_FULL'],
      'reasons': ['Gets you to Mombasa first: arrives Sun 11 Oct at 20:00.', 'Only 2 seats left in your cabin.'],
    });
    var chosen = false;
    await tester.pumpWidget(MaterialApp(
      theme: kestrelTheme(),
      home: Scaffold(body: FlightOptionCard(flight: flight, recommended: true, onSelect: () => chosen = true)),
    ));
    expect(find.text('EARLIEST ARRIVAL'), findsOneWidget);
    expect(find.text('SAME DAY'), findsOneWidget);
    expect(find.text('ALMOST FULL'), findsOneWidget);
    expect(find.text('Only 2 seats left in your cabin.'), findsNothing);
    await tester.tap(find.text('Why this flight?'));
    await tester.pumpAndSettle();
    expect(find.text('Only 2 seats left in your cabin.'), findsOneWidget);
    expect(chosen, isFalse); // the reasons are not the card's "choose" target
  });

  testWidgets('the chips are the server\'s next steps; "Check my case" opens Help', (tester) async {
    final backend = _Backend()
      ..tripSuggestions = [
        {'label': 'Check my case', 'intent': 'case'},
        {'label': 'What am I entitled to?', 'intent': 'entitlements'},
      ];
    await _signIn(tester, backend: backend);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.text('Check my case'), findsOneWidget);
    expect(find.text('Talk to a person'), findsNothing); // a case is already open
    await _tapText(tester, 'Check my case');
    expect(find.text('How can we help?'), findsOneWidget); // the Help section
    expect(backend.chatRequests, isEmpty); // done in the app, not by the assistant
  });

  testWidgets('a saved conversation continues, and "Start over" clears it', (tester) async {
    final backend = _Backend()
      ..historyTurns = [
        {'role': 'user', 'content': 'Can I get a refund?', 'created_at': '2026-10-17T11:05:00+00:00'},
        {'role': 'assistant', 'content': 'Yes, you can choose a refund.', 'created_at': '2026-10-17T11:05:09+00:00'},
      ];
    await _signIn(tester, backend: backend);
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Continuing your conversation from Sat 17 Oct'), findsOneWidget);
    expect(find.text('Yes, you can choose a refund.'), findsOneWidget);
    expect(find.textContaining('Hello Grace'), findsNothing); // no new greeting

    await _tapText(tester, 'Start over');
    expect(backend.historyDeletes, 1);
    expect(find.textContaining('Continuing your conversation'), findsNothing);
    expect(find.text('Yes, you can choose a refund.'), findsNothing);
    expect(find.textContaining('Hello Grace'), findsOneWidget);
  });

  test('the calendar file is the booked flight, in UTC', () {
    final booking = Booking({
      ..._me,
      'booking_status': 'REACCOMMODATED',
      'seat_number': '3C',
      'current_flight': {
        'flight_number': 'KQ102',
        'departure_time': '2026-10-11T16:00:00+00:00',
        'arrival_time': '2026-10-11T17:00:00+00:00',
        'departure_local': '2026-10-11T19:00+03:00',
      },
    });
    final ics = calendarFile(booking, now: DateTime.utc(2026, 10, 10))!;
    expect(ics, contains('DTSTART:20261011T160000Z'));
    expect(ics, contains('DTEND:20261011T170000Z'));
    expect(ics, contains('SUMMARY:KQ102 NBO-MBA'));
    expect(ics, contains('seat 3C'));
    expect(calendarFile(Booking(_me)), isNull); // not rebooked yet
  });

  // UI UX Pro Max pre-delivery checks for the new passenger screens.
  for (final (name, size, scale) in [
    ('375 px phone', const Size(375, 667), 1.0),
    ('phone landscape', const Size(844, 390), 1.0),
    ('larger text', const Size(412, 915), 1.5),
  ]) {
    testWidgets('My trip (Kestrel recommends) and the assistant\'s chips hold up: $name', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      await _signIn(tester, screen: size);
      expect(find.text('KESTREL RECOMMENDS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.tap(find.text('Assistant'));
      await tester.pumpAndSettle();
      expect(find.text('Talk to a person'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('with reduce-motion, skeletons and the typing cursor stand still', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: kestrelTheme(),
      home: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Scaffold(body: Column(children: [TripSkeleton(rows: 1), TypingCursor()])),
      ),
    ));
    // Nothing keeps scheduling frames, so the tree settles at once.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('staff see a frustration hand-off as "Frustrated passenger"', (tester) async {
    await _pump(tester, _Backend(staffQueue: [{..._case(), 'trigger': 'FRUSTRATION'}]).client, screen: laptop);
    await _toStaffForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'Wanjiru');
    await tester.enterText(find.byType(TextFormField).at(1), 'desk-key');
    await _tapText(tester, 'Open the desk');
    expect(find.text('Frustrated passenger'), findsWidgets);
  });

  testWidgets('503 from the assistant: "busy right now", with the way back to the trip', (tester) async {
    await _signIn(tester, backend: _Backend(chatStatus: 503));
    await tester.tap(find.text('Assistant'));
    await tester.pumpAndSettle();
    await _tapText(tester, 'What am I entitled to?');

    expect(find.text('The assistant is busy right now'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await _tapText(tester, 'Back to my trip');
    expect(find.text('Hi, Grace'), findsOneWidget);
  });

  test('the Google mark is parsed from its official paths', () {
    final g = parseSvgPath('M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0z').getBounds();
    expect(g.left, greaterThanOrEqualTo(0));
    expect(g.right, lessThanOrEqualTo(48));
    expect(g.width, greaterThan(10));
    expect(maskEmail('steven.a@example.com'), 's••••••@example.com');
    expect(isValidEmail('steven.a@example.com'), isTrue);
    expect(isValidEmail('steven.example.com'), isFalse);
  });

  test('theme text colours keep 4.5:1 contrast on every surface they sit on', () {
    double lum(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final (hi, lo) = lum(a) > lum(b) ? (lum(a), lum(b)) : (lum(b), lum(a));
      return (hi + .05) / (lo + .05);
    }

    for (final bg in [K.void_, K.base, K.inset, K.surface, K.elevated]) {
      // K.sky: the "HOTEL INCLUDED" flight badge.
      for (final c in [K.textPrimary, K.textSecondary, K.glow, K.teal, K.amber, K.sky]) {
        expect(ratio(c, bg), greaterThanOrEqualTo(4.5), reason: '$c on $bg');
      }
    }
    // White on the crimson fills (buttons, the current recovery step, the
    // sidebar's active tile) and dark text on amber (an open case).
    expect(ratio(Colors.white, K.crimson), greaterThanOrEqualTo(4.5));
    expect(ratio(Colors.white, K.crimson600), greaterThanOrEqualTo(4.5));
    expect(ratio(K.base, K.amber), greaterThanOrEqualTo(4.5));
    // The chosen booking on Link booking: a teal tint over the card.
    for (final bg in [K.surface, K.inset]) {
      final tinted = Color.alphaBlend(K.tealSoft, bg);
      for (final c in [K.textPrimary, K.textSecondary, K.teal]) {
        expect(ratio(c, tinted), greaterThanOrEqualTo(4.5), reason: '$c on tealSoft over $bg');
      }
    }
  });
}
