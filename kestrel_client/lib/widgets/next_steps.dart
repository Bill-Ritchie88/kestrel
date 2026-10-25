import 'package:flutter/material.dart';

import '../api/models.dart';
import '../calendar.dart';
import '../state/session.dart';
import '../state/shell.dart';

/// A suggested next step (src/kestrel/suggestions.py), wherever it is tapped
/// (the assistant's chips, My trip): a quick reply goes to the assistant with
/// its intent, a message as if typed; `calendar` and `case` are done here.
Future<void> runSuggestion(
  BuildContext context,
  Suggestion s, {
  required void Function(String text, {String? intent}) ask,
}) async {
  switch (s.intent) {
    case 'calendar':
      final booking = SessionScope.read(context).booking;
      final saved = booking != null && downloadCalendar(booking);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved
            ? 'Your flight is in kestrel-${booking.pnr.toLowerCase()}.ics. Open it to add it to your calendar.'
            : 'The calendar file can be saved from the website.'),
      ));
    case 'case':
      ShellScope.read(context).go(Section.help);
    case 'alternatives' || 'entitlements' || 'person':
      ask(s.label, intent: s.intent);
    default:
      ask(s.message);
  }
}

IconData? suggestionIcon(Suggestion s) => switch (s.intent) {
      'person' => Icons.support_agent,
      'calendar' => Icons.event_outlined,
      'case' => Icons.inbox_outlined,
      _ => null,
    };
