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

/// Airports on the simulated network.
const cities = {
  'NBO': 'Nairobi', 'MBA': 'Mombasa', 'KIS': 'Kisumu', 'EDL': 'Eldoret',
  'MYD': 'Malindi', 'UKA': 'Ukunda', 'EBB': 'Entebbe', 'DAR': 'Dar es Salaam',
  'ZNZ': 'Zanzibar', 'KGL': 'Kigali', 'BJM': 'Bujumbura', 'ADD': 'Addis Ababa',
  'MGQ': 'Mogadishu', 'JUB': 'Juba', 'HRE': 'Harare', 'LUN': 'Lusaka',
  'LLW': 'Lilongwe', 'JNB': 'Johannesburg', 'FIH': 'Kinshasa', 'LOS': 'Lagos',
  'ACC': 'Accra', 'ABV': 'Abuja', 'DXB': 'Dubai', 'BOM': 'Mumbai',
  'LHR': 'London', 'CDG': 'Paris', 'AMS': 'Amsterdam', 'BKK': 'Bangkok',
  'JFK': 'New York',
};

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
