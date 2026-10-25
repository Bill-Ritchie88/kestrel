import 'package:flutter/material.dart';

import '../api/kestrel_api.dart';
import '../state/public.dart';
import '../state/session.dart';

/// Turns a failed call into a message for the screen. When the 15-minute
/// session has ended (401), signs the passenger out onto the "session
/// expired" page instead and returns null, so the caller shows nothing
/// further.
String? handleApiError(BuildContext context, Object error) {
  if (error is ApiException && error.sessionExpired) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    PublicScope.read(context).sessionExpired();
    SessionScope.read(context).signOut();
    return null;
  }
  if (error is ApiException) return error.message;
  return 'Something went wrong. Please try again.';
}

/// The words for a load that failed, with no side effect (the passenger
/// layout handles a 401 itself, once).
String failureMessage(Object error) =>
    error is ApiException ? error.message : 'Something went wrong. Please try again.';
