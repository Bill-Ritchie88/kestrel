import 'package:flutter/widgets.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';
import '../auth/account_auth.dart';
import 'trip.dart';

/// Who is using the app: a passenger (booking + 15-minute token) or a member
/// of staff at the disruption desk (name + shared staff key). Held in memory
/// only: nothing is written to device storage.
class Session extends ChangeNotifier {
  Session({KestrelApi? api, AccountAuth? auth, this.tripMaxAge = const Duration(seconds: 60)})
      : api = api ?? KestrelApi(),
        auth = auth ?? const UnavailableAccountAuth();

  final KestrelApi api;

  /// Google and emailed-code sign-in (Supabase), when the build has it.
  final AccountAuth auth;
  Booking? booking;

  /// The passenger's trip (GET /api/trip), loading from the moment they sign
  /// in. The source for every section; [booking] follows it.
  TripStore? trip;

  /// How old the trip may get before a section switch refreshes it.
  final Duration tripMaxAge;

  /// The account signed in with, when it is linked to this booking: the
  /// account menu then offers "Unlink this booking".
  AccountIdentity? linkedAccount;

  /// Recorded as `STAFF:name` on the cases this person resolves.
  String? staffName;

  bool get signedIn => api.token != null && booking != null;
  bool get staffSignedIn => api.staffKey != null && staffName != null;

  Future<void> signIn(String pnr, String surname) async {
    final body = await api.login(pnr, surname);
    linkedAccount = null;
    _start(asMap(body['passenger']));
  }

  /// Exchanges a signed-in account for a Kestrel session. Returns the
  /// bookings to offer when the account has none linked yet; null when
  /// signed in.
  Future<List<LinkSuggestion>?> signInWithAccount(AccountIdentity identity, {String? pnr, String? lastName}) async {
    final result = await api.accountSession(identity.accessToken, pnr: pnr, lastName: lastName);
    if (result.linkRequired) return result.suggestions;
    linkedAccount = result.linked ? identity : null;
    _start(result.passenger);
    return null;
  }

  /// Signed in. The layout opens at once, with the name and booking
  /// reference the sign-in returned, while the whole trip loads (one call);
  /// the sections show skeletons until it arrives.
  void _start(Map<String, dynamic> passenger) {
    trip?.dispose();
    final store = trip = TripStore(api, maxAge: tripMaxAge, onBooking: (b) {
      booking = b;
      notifyListeners();
    });
    booking = Booking({
      'pnr_code': passenger['pnr_code'] ?? '',
      'passenger': {'last_name': passenger['last_name'] ?? '', 'rewards_tier': passenger['rewards_tier']},
    });
    notifyListeners();
    store.refreshQuietly();
  }

  /// The latest trip from the server; [booking] is updated with it.
  Future<Booking> refresh() async {
    await trip?.refresh();
    return booking!;
  }

  /// Checks the key against the queue before opening the desk, so a wrong
  /// key is reported on the sign-in form rather than on an empty dashboard.
  Future<void> signInStaff(String name, String key) async {
    api.staffKey = key.trim();
    try {
      await api.staffCases(status: 'OPEN', limit: 1);
    } catch (_) {
      api.staffKey = null;
      rethrow;
    }
    staffName = name.trim();
    notifyListeners();
  }

  /// Removes the account's link to this booking, then signs out: the next
  /// sign-in with the account asks for a booking again.
  Future<void> unlinkBooking() async {
    final account = linkedAccount;
    if (account == null) return;
    await api.unlinkAccount(account.accessToken);
    signOut();
  }

  /// Signs out of Kestrel and of the account (Supabase) together.
  void signOut() {
    api.logout();
    linkedAccount = null;
    api.staffKey = null;
    trip?.dispose();
    trip = null;
    booking = null;
    staffName = null;
    auth.signOut();
    notifyListeners();
  }
}

class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child})
      : super(notifier: session);

  static Session of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;

  static Session read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SessionScope>()!.notifier!;
}
