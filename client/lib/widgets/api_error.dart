import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../state/session.dart';

/// Turns a failed call into a message for the screen. When the 15-minute
/// session has ended (401), returns the passenger to sign-in instead and
/// returns null, so the caller shows nothing further.
String? handleApiError(BuildContext context, Object error) {
  if (error is ApiException && error.sessionExpired) {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).popUntil((route) => route.isFirst);
    SessionScope.read(context).signOut();
    messenger.showSnackBar(
      const SnackBar(content: Text('Your session has ended. Please sign in again.')),
    );
    return null;
  }
  if (error is ApiException) return error.message;
  return 'Something went wrong. Please try again.';
}
