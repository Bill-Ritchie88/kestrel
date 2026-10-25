import 'package:flutter/foundation.dart';

/// Where the client finds the two backend services.
///
/// Override at build time:
///   flutter run -d chrome --web-port 5173 \
///     --dart-define=API_BASE=http://127.0.0.1:8000 \
///     --dart-define=AGENT_BASE=http://127.0.0.1:8001
///
/// The Android emulator reaches the host machine at 10.0.2.2, not 127.0.0.1.
class AppConfig {
  static const _apiOverride = String.fromEnvironment('API_BASE');
  static const _agentOverride = String.fromEnvironment('AGENT_BASE');

  static String get _host =>
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          ? 'http://10.0.2.2'
          : 'http://127.0.0.1';

  static String get apiBase =>
      _apiOverride.isNotEmpty ? _apiOverride : '$_host:8000';

  static String get agentBase =>
      _agentOverride.isNotEmpty ? _agentOverride : '$_host:8001';

  /// Matches TOKEN_TTL_SECONDS in src/kestrel/api/auth.py (FR-01).
  static const sessionMinutes = 15;

  /// Supabase Auth, for Google and emailed-code sign-in:
  ///   `--dart-define=SUPABASE_URL=https://<ref>.supabase.co`
  ///   `--dart-define=SUPABASE_ANON_KEY=<anon key>`
  /// Without both, the sign-in page offers only the booking reference and
  /// the staff key.
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static bool get accountSignIn => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Where Google sends the Android app back to (a deep link; see
  /// kestrel_client/README.md). In a browser it is the page's own address.
  static const appAuthRedirect = 'io.kestrel.app://login-callback';
}
