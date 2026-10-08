/// Typed views of the REST tier's JSON. Field names follow the API exactly
/// (src/kestrel/api/main.py and booking.py).
library;

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

  String get clauseRef => json['clause_ref'] as String? ?? '';
  double get similarity => (json['similarity'] as num?)?.toDouble() ?? 0;
  String? get sourceUrl => json['source_url'] as String?;
}

class HandoffCase {
  HandoffCase(this.json);
  final Map<String, dynamic> json;

  int get id => (json['case_id'] as num?)?.toInt() ?? 0;
  String get trigger => json['trigger'] as String? ?? '';
  String get status => json['status'] as String? ?? '';
  String? get createdAt => json['created_at'] as String?;
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
}

/// Helpers shared by the parsers in the screens.
Map<String, dynamic> asMap(Object? v) => _map(v);
List<Map<String, dynamic>> asList(Object? v) => _list(v);
