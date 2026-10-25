/// Display helpers. Times arrive from the API already in each airport's
/// local time with the offset attached (departure_local, e.g.
/// "2026-10-11T16:21+03:00"), so they are shown as written and never
/// converted to the device's time zone.
library;

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Airport names, as the REST tier sends them with the trip and the account
/// suggestions (`cities`, from kestrel/airports.py: the one list). A code
/// with no name yet is shown as the code.
final cities = <String, String>{};

/// Adds the names in a response's `cities` field.
void learnCities(Object? json) {
  if (json is Map) {
    json.forEach((code, name) {
      if (code is String && name is String) cities[code] = name;
    });
  }
}

String city(String code) => cities[code] ?? code;

/// "16:21" from "2026-10-11T16:21+03:00".
String hhmm(String? localIso) =>
    (localIso == null || localIso.length < 16) ? '--:--' : localIso.substring(11, 16);

/// The calendar date as written in the local time string.
DateTime? _localDate(String? localIso) {
  if (localIso == null || localIso.length < 10) return null;
  return DateTime.tryParse(localIso.substring(0, 10));
}

/// "Sun 11 Oct".
String dayLabel(String? localIso) {
  final d = _localDate(localIso);
  if (d == null) return '';
  return '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

/// "+1 day" when [laterIso] falls on a later local date than [earlierIso].
String dayOffset(String? earlierIso, String? laterIso) {
  final a = _localDate(earlierIso), b = _localDate(laterIso);
  if (a == null || b == null) return '';
  final n = b.difference(a).inDays;
  return n <= 0 ? '' : '+$n day${n == 1 ? '' : 's'}';
}

/// "9h 25m" between two absolute times (offsets respected).
String duration(String? fromIso, String? toIso) {
  final a = fromIso == null ? null : DateTime.tryParse(fromIso);
  final b = toIso == null ? null : DateTime.tryParse(toIso);
  if (a == null || b == null) return '';
  final m = b.difference(a).inMinutes;
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

String money(double? amount, String? currency) {
  if (amount == null) return '';
  final whole = amount == amount.roundToDouble();
  final n = whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
  final grouped = n.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${currency ?? ''} $grouped'.trim();
}

/// "Sat 17 Oct, 14:05" in the device's time zone (a server timestamp, e.g.
/// when a conversation was last saved).
String dayTime(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '';
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}, $hm';
}

/// When something happened, for the staff desk: "5 min ago", "3 h ago",
/// else "Sun 11 Oct, 14:05" ([compact]: "Sun 11 Oct", for a table column
/// that must stay narrow). Server timestamps are absolute, so these ARE
/// shown in the device's time zone (unlike flight times).
String since(String? iso, {DateTime? now, bool compact = false}) {
  final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  final day = '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
  if (compact) return day;
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return '$day, $hm';
}

final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

bool isValidEmail(String s) => _email.hasMatch(s.trim());

/// "s••••••@example.com": enough to recognise, not enough to read out.
String maskEmail(String email) {
  final e = email.trim();
  final at = e.indexOf('@');
  if (at < 1) return e;
  return '${e[0]}${'•' * 6}${e.substring(at)}';
}

String initials(String first, String last) {
  final a = first.trim(), b = last.trim();
  final s = '${a.isEmpty ? '' : a[0]}${b.isEmpty ? '' : b[0]}'.toUpperCase();
  return s.isEmpty ? '?' : s;
}

String titleCase(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

const reasonText = {
  'TECHNICAL': 'a technical problem',
  'CREW': 'crew availability',
  'OPERATIONAL': 'an operational problem',
  'WEATHER': 'weather',
  'ATC': 'an air traffic control restriction',
  'SECURITY': 'a security issue',
  'POLITICAL': 'political unrest',
};
