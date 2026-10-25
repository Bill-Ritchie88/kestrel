/// Typed views of the REST tier's JSON. Field names follow the API exactly
/// (src/kestrel/api/main.py and booking.py).
library;

import '../format.dart';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _list(Object? v) =>
    v is List ? v.map(_map).toList() : <Map<String, dynamic>>[];

class Flight {
  Flight(this.json);
  final Map<String, dynamic> json;

  String get id => json['flight_id'] as String? ?? '';
  String get number => json['flight_number'] as String? ?? '';
  String get origin => json['origin'] as String? ?? '';
  String get destination => json['destination'] as String? ?? '';
  String? get status => json['status'] as String?;
  String? get disruptionReason => json['disruption_reason'] as String?;
  String? get departureLocal => json['departure_local'] as String?;
  String? get arrivalLocal => json['arrival_local'] as String?;
  String? get cabin => json['cabin_class'] as String?;
  int get seatsLeft => (json['available_seats'] as num?)?.toInt() ?? 0;
  String? get aircraft => json['aircraft_type'] as String?;

  /// Why this flight (src/kestrel/api/explain.py): plain sentences, badges
  /// (EARLIEST_ARRIVAL, MOST_SEATS, SAME_DAY, NEXT_DAY_HOTEL, ALMOST_FULL),
  /// hours after the original departure, and what the rules would give with
  /// it ({entitlement_type, label, quantity, amount, currency, points}).
  List<String> get reasons => (json['reasons'] as List?)?.map((e) => e.toString()).toList() ?? const [];
  List<String> get badges => (json['badges'] as List?)?.map((e) => e.toString()).toList() ?? const [];
  double? get waitHours => (json['wait_hours'] as num?)?.toDouble();
  List<Map<String, dynamic>> get includes => _list(json['includes']);
}

class Booking {
  Booking(this.json);
  final Map<String, dynamic> json;

  String get pnr => json['pnr_code'] as String? ?? '';
  String get status => json['booking_status'] as String? ?? '';
  Map<String, dynamic> get passenger => _map(json['passenger']);
  String get firstName => passenger['first_name'] as String? ?? '';
  String get lastName => passenger['last_name'] as String? ?? '';
  String get tier => passenger['rewards_tier'] as String? ?? 'BLUE';
  Flight get original => Flight(_map(json['original_flight']));
  Flight? get current =>
      json['current_flight'] == null ? null : Flight(_map(json['current_flight']));
  String? get seat => json['seat_number'] as String?;
  String get cabin => json['cabin_class'] as String? ?? 'ECONOMY';
  bool get isDisrupted => status == 'DISRUPTED';
  bool get isRebooked => status == 'REACCOMMODATED';
}

class Voucher {
  Voucher(this.json);
  final Map<String, dynamic> json;

  String get code => json['voucher_code'] as String? ?? '';
  String get type => json['entitlement_type'] as String? ?? '';
  int get quantity => (json['quantity'] as num?)?.toInt() ?? 1;
  double? get amount => (json['amount'] as num?)?.toDouble();
  String? get currency => json['currency'] as String?;
  int? get points => (json['points'] as num?)?.toInt();
  String get status => json['status'] as String? ?? '';
  String get basis => json['basis'] as String? ?? '';
  String? get validUntil => json['valid_until'] as String?;
  bool get isLive => status == 'ISSUED' || status == 'ELIGIBLE';
}

class Entitlement {
  Entitlement(this.json);
  final Map<String, dynamic> json;

  String get type => json['entitlement_type'] as String? ?? '';
  String get label => json['label'] as String? ?? '';
  String get status => json['status'] as String? ?? '';
  String get explanation => json['explanation'] as String? ?? '';
  String get basis => json['basis'] as String? ?? '';
  int get quantity => (json['quantity'] as num?)?.toInt() ?? 1;
  double? get amount => (json['amount'] as num?)?.toDouble();
  String? get currency => json['currency'] as String?;
  int? get points => (json['points'] as num?)?.toInt();
}

class EntitlementDecision {
  EntitlementDecision(this.json);
  final Map<String, dynamic> json;

  String? get regulation => json['regulation'] as String?;
  List<Entitlement> get entitlements =>
      _list(json['entitlements']).map(Entitlement.new).toList();
  List<String> get notes =>
      (json['notes'] as List?)?.map((e) => e.toString()).toList() ?? const [];
}

class PolicyHit {
  PolicyHit(this.json);
  final Map<String, dynamic> json;

  // The retriever says clause_ref; the scores saved on a hand-off case
  // (agent.py) say ref.
  String get clauseRef => (json['clause_ref'] ?? json['ref']) as String? ?? '';
  double get similarity => (json['similarity'] as num?)?.toDouble() ?? 0;
  String? get sourceUrl => json['source_url'] as String?;
}

/// A hand-off case (handoff.py `case_to_dict`). The passenger's own cases and
/// the staff queue (FR-09) share this shape.
class HandoffCase {
  HandoffCase(this.json);
  final Map<String, dynamic> json;

  int get id => (json['case_id'] as num?)?.toInt() ?? 0;
  String get pnr => json['pnr_code'] as String? ?? '';
  String get trigger => json['trigger'] as String? ?? '';
  String get status => json['status'] as String? ?? '';
  bool get isOpen => status == 'OPEN';
  String? get bookingStatus => json['booking_status'] as String?;
  String? get question => json['question'] as String?;
  String? get summary => json['summary'] as String?;
  double? get topSimilarity => (json['top_similarity'] as num?)?.toDouble();
  List<PolicyHit> get similarityScores =>
      _list(json['similarity_scores']).map(PolicyHit.new).toList();
  String? get createdAt => json['created_at'] as String?;
  String? get resolvedAt => json['resolved_at'] as String?;
  String? get resolvedBy => json['resolved_by'] as String?;
  String? get resolutionNote => json['resolution_note'] as String?;
}

/// A suggested next step (src/kestrel/suggestions.py): a quick reply
/// [intent] (alternatives, entitlements, person - run without the model;
/// calendar, case - handled here), or a [message] sent as if typed.
class Suggestion {
  Suggestion(this.json);
  final Map<String, dynamic> json;

  String get label => json['label'] as String? ?? '';
  String? get intent => json['intent'] as String?;
  String get message => json['message'] as String? ?? label;
}

/// GET /api/trip: everything My trip, Flights, Vouchers and Help show, in
/// the shapes of the single endpoints.
class Trip {
  Trip(this.json) {
    learnCities(json['cities']);
  }
  final Map<String, dynamic> json;

  Booking get booking => Booking(_map(json['booking']));
  List<Flight> get alternatives => _list(json['alternatives']).map(Flight.new).toList();
  EntitlementDecision get decision => EntitlementDecision(_map(_map(json['entitlements'])['decision']));
  List<Voucher> get vouchers => _list(_map(json['entitlements'])['vouchers']).map(Voucher.new).toList();
  List<HandoffCase> get cases => _list(json['cases']).map(HandoffCase.new).toList();
  List<Suggestion> get suggestions => _list(json['suggestions']).map(Suggestion.new).toList();
}

/// A booking under the signed-in account's verified email, offered for
/// linking (POST /api/auth/account answered link_required).
class LinkSuggestion {
  LinkSuggestion(this.json);
  final Map<String, dynamic> json;

  String get pnr => json['pnr_code'] as String? ?? '';
  String get origin => json['origin'] as String? ?? '';
  String get destination => json['destination'] as String? ?? '';

  /// "2026-10-15": the local date at the departure airport.
  String? get departureDate => json['departure_date'] as String?;
  String get bookingStatus => json['booking_status'] as String? ?? '';
}

/// What POST /api/auth/account answered: signed in (the token is now held
/// by the client), or the account still needs a booking linked.
class AccountSessionResult {
  AccountSessionResult.signedIn(this.passenger, {this.linked = true})
      : suggestions = const [],
        linkRequired = false;
  AccountSessionResult.link(this.suggestions)
      : linkRequired = true,
        linked = false,
        passenger = const {};

  final bool linkRequired;

  /// The account is linked to this booking's passenger. False when a booking
  /// reference and surname opened someone else's booking for this visit only.
  final bool linked;
  final List<LinkSuggestion> suggestions;

  /// Signed in: the booking's last name, tier and reference.
  final Map<String, dynamic> passenger;
}

/// One structured result the agent produced during a chat turn
/// (agent.py `_emit`): alternatives, rebooked, policy, entitlements,
/// handoff or error.
class AgentEvent {
  AgentEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;

  factory AgentEvent.fromJson(Map<String, dynamic> j) =>
      AgentEvent(j['type'] as String? ?? '', _map(j['data']));
}

class ChatReply {
  ChatReply(this.json);
  final Map<String, dynamic> json;

  String get reply => json['reply'] as String? ?? '';
  List<AgentEvent> get events =>
      _list(json['events']).map(AgentEvent.fromJson).toList();
  int? get totalMs => (_map(json['timing'])['total_ms'] as num?)?.toInt();
  int? get firstTokenMs => (_map(json['timing'])['first_token_ms'] as num?)?.toInt();

  /// What to offer next (src/kestrel/suggestions.py after_turn).
  List<Suggestion> get suggestions => _list(json['suggestions']).map(Suggestion.new).toList();
}

/// One saved turn of the booking's conversation (GET /api/chat/history).
class HistoryTurn {
  HistoryTurn(this.json);
  final Map<String, dynamic> json;

  bool get fromUser => json['role'] == 'user';
  String get content => json['content'] as String? ?? '';
  String? get createdAt => json['created_at'] as String?;
}

/// One Server-Sent Event of a streamed turn: status, delta, event, done or
/// error, with its JSON data.
class ChatStreamEvent {
  ChatStreamEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// Helpers shared by the parsers in the screens.
Map<String, dynamic> asMap(Object? v) => _map(v);
List<Map<String, dynamic>> asList(Object? v) => _list(v);
