/// "Add my new flight to my calendar" (suggestion intent `calendar`): an
/// iCalendar file for the flight the passenger is booked on, built here from
/// the booking - no server call.
library;

import 'api/models.dart';
import 'calendar_download.dart';
import 'format.dart';

String _utc(String iso) {
  final t = DateTime.parse(iso).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
}

/// The .ics text for [booking]'s current flight, or null if it has none.
String? calendarFile(Booking booking, {DateTime? now}) {
  final f = booking.current;
  final start = f?.json['departure_time'] as String?;
  if (f == null || start == null) return null;
  final end = f.json['arrival_time'] as String? ?? start;
  final route = '${booking.original.origin}-${booking.original.destination}';
  final stamp = _utc((now ?? DateTime.now()).toUtc().toIso8601String());
  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Kestrel//Disruption assistant//EN',
    'BEGIN:VEVENT',
    'UID:${booking.pnr}-${f.number}-${_utc(start)}@kestrel',
    'DTSTAMP:$stamp',
    'DTSTART:${_utc(start)}',
    'DTEND:${_utc(end)}',
    'SUMMARY:${f.number} $route',
    'LOCATION:${city(booking.original.origin)}',
    'DESCRIPTION:Kenya Airways ${f.number}\\, booking ${booking.pnr}\\, seat ${booking.seat ?? '-'}. '
        'Departs ${hhmm(f.departureLocal)} local time.',
    'END:VEVENT',
    'END:VCALENDAR',
    '',
  ].join('\r\n');
}

/// Offers the file to the browser as a download. False where that is not
/// possible (outside a browser, e.g. the test runner), so the caller can say so.
bool downloadCalendar(Booking booking) {
  final ics = calendarFile(booking);
  if (ics == null) return false;
  return saveTextFile('kestrel-${booking.pnr.toLowerCase()}.ics', 'text/calendar', ics);
}
