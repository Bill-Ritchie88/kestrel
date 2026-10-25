import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'auth/supabase_account_auth.dart';
import 'screens/passenger_shell.dart';
import 'screens/public_site.dart';
import 'screens/staff_loader.dart';
import 'state/public.dart';
import 'state/session.dart';
import 'state/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Google and emailed-code sign-in, when the build has the Supabase
  // settings. Supabase connects in the background: the first screen never
  // waits for it.
  runApp(KestrelApp(session: Session(auth: startAccountAuth())));
}

/// Project Kestrel client (FR-08, FR-09).
///
/// Talks to two services:
///   REST tier   :8000  sign-in, booking, flights, rebooking, vouchers, hand-off,
///                      staff case queue
///   Agent       :8001  POST /api/chat (Gemini + tools, no database access)
class KestrelApp extends StatelessWidget {
  KestrelApp({super.key, required this.session, ShellController? shell, PublicController? public})
      : shell = shell ?? ShellController(),
        public = public ?? PublicController();
  final Session session;
  final ShellController shell;
  final PublicController public;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      // Both above the Navigator, so pages pushed over a layout can switch
      // section, and a 401 anywhere can open the "session expired" page.
      child: ShellScope(
        shell: shell,
        child: PublicScope(
          public: public,
          child: MaterialApp(
            title: kIsWeb ? 'Kestrel Web — disruption assistant' : 'Kestrel App',
            debugShowCheckedModeBanner: false,
            theme: kestrelTheme(),
            darkTheme: kestrelTheme(),
            themeMode: ThemeMode.dark,
            home: const SessionGate(),
          ),
        ),
      ),
    );
  }
}

/// The public site (Home, Help, sign-in) until a passenger's booking is
/// loaded (the passenger app) or a member of staff is signed in (the staff
/// desk). Signing out, or a 401 from any call, flips it back.
class SessionGate extends StatelessWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (session.staffSignedIn) return const StaffDesk();
    if (!session.signedIn) return const PublicSite();
    // A new key per booking resets the layout and conversation for a new passenger.
    return PassengerShell(key: ValueKey(session.booking!.pnr));
  }
}
