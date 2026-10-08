import 'package:flutter/widgets.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';

/// The signed-in passenger. Held in memory only: the token lives 15 minutes
/// (FR-01) and is never written to device storage.
class Session extends ChangeNotifier {
  Session({KestrelApi? api}) : api = api ?? KestrelApi();

  final KestrelApi api;
  Booking? booking;

  bool get signedIn => api.token != null && booking != null;

  Future<void> signIn(String pnr, String surname) async {
    await api.login(pnr, surname);
    try {
      booking = await api.me();
    } catch (_) {
      api.logout(); // never leave a token without a booking behind it
      rethrow;
    }
    notifyListeners();
  }

  Future<Booking> refresh() async {
    booking = await api.me();
    notifyListeners();
    return booking!;
  }

  void signOut() {
    api.logout();
    booking = null;
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
