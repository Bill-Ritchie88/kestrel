import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';
import 'screens/login_screen.dart';
import 'state/session.dart';
import 'theme.dart';

void main() => runApp(KestrelApp(session: Session()));

/// Project Kestrel passenger client (FR-08).
///
/// Talks to two services:
///   REST tier   :8000  sign-in, booking, flights, rebooking, vouchers, hand-off
///   Agent       :8001  POST /api/chat (Gemini + tools, no database access)
class KestrelApp extends StatelessWidget {
  const KestrelApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      child: MaterialApp(
        title: 'Kestrel · Kenya Airways',
        debugShowCheckedModeBanner: false,
        theme: kestrelTheme(),
        darkTheme: kestrelTheme(),
        themeMode: ThemeMode.dark,
        home: const SessionGate(),
      ),
    );
  }
}

/// Sign-in until a booking is loaded, then the chat. Signing out (or a 401
/// from any call) flips it back.
class SessionGate extends StatelessWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (!session.signedIn) return const LoginScreen();
    // A new key per booking resets the conversation for a new passenger.
    return ChatScreen(key: ValueKey(session.booking!.pnr));
  }
}
