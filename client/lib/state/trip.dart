import 'package:flutter/widgets.dart';

import '../api/kestrel_api.dart';
import '../api/models.dart';

/// The passenger's whole trip - booking, flights to move to, entitlements and
/// vouchers, hand-off cases, suggested next steps - from one call,
/// GET /api/trip, made once after sign-in.
///
/// It is the source for My trip, Flights, Vouchers and Help, so switching
/// section shows what is already here at once, with no request. It refreshes
/// itself quietly in the background (stale-while-revalidate): after a
/// rebooking or a hand-off (callers ask), when a section is shown and the data
/// is over a minute old, and on pull-to-refresh. A refresh that fails keeps
/// what is on screen.
class TripStore extends ChangeNotifier {
  TripStore(this._api, {this.onBooking, this.maxAge = const Duration(seconds: 60), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final KestrelApi _api;

  /// Told about every booking that arrives, so the rest of the app (the top
  /// bar, the session) shows the same one.
  final ValueChanged<Booking>? onBooking;

  /// Older than this, the next section switch refreshes the trip.
  final Duration maxAge;
  final DateTime Function() _now;

  Trip? trip;

  /// Why the last load failed (an [ApiException], usually), until one works.
  Object? failure;
  DateTime? loadedAt;
  Future<void>? _inFlight;
  bool _disposed = false;

  bool get loading => _inFlight != null;
  bool get stale => loadedAt == null || _now().difference(loadedAt!) >= maxAge;

  /// Loads the trip, or joins the load already under way. Throws what the
  /// load threw (it is also kept in [failure]).
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    final load = _inFlight = _load().whenComplete(() {
      _inFlight = null;
      _notify();
    });
    _notify(); // listeners can show that a load is under way
    return load;
  }

  /// A refresh in the background, if the trip is over [maxAge] old.
  void refreshIfStale() {
    if (stale && _inFlight == null) refresh().catchError((Object _) {});
  }

  /// A refresh in the background, now (after a rebooking or a hand-off).
  void refreshQuietly() => refresh().catchError((Object _) {});

  Future<void> _load() async {
    try {
      final t = await _api.trip();
      if (_disposed) return;
      trip = t;
      failure = null;
      loadedAt = _now();
      onBooking?.call(t.booking);
    } catch (e) {
      if (_disposed) return;
      failure = e;
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class TripScope extends InheritedNotifier<TripStore> {
  const TripScope({super.key, required TripStore store, required super.child}) : super(notifier: store);

  static TripStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TripScope>()!.notifier!;

  static TripStore read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TripScope>()!.notifier!;

  /// Outside the passenger app (e.g. a widget test of one card), null.
  static TripStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TripScope>()?.notifier;
}
