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
}
