import 'package:flutter/foundation.dart';

/// Build-time configuration. Pass with --dart-define, e.g.
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000/api
/// No secrets ever live here: anything in a web build is public.
abstract final class AppConfig {
  /// development | staging | production
  static const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'development');

  /// Base URL of the Signal HRM API including the global prefix (no trailing slash).
  /// Production serves the app and API from one origin (Caddy proxies /api), so the default is relative.
  static const _rawApiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: appEnv == 'production' ? '/api' : 'http://localhost:3000/api');

  /// Resolved base URL that automatically maps localhost to 10.0.2.2 on Android devices/emulators.
  static String get apiBaseUrl {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      if (_rawApiBaseUrl.contains('localhost')) {
        return _rawApiBaseUrl.replaceAll('localhost', '10.0.2.2');
      } else if (_rawApiBaseUrl.contains('127.0.0.1')) {
        return _rawApiBaseUrl.replaceAll('127.0.0.1', '10.0.2.2');
      }
    }
    return _rawApiBaseUrl;
  }

  /// Public OAuth client ids (not secrets). Empty = the button is hidden.
  static const googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const appleClientId = String.fromEnvironment('APPLE_CLIENT_ID');
  static const appleRedirectUri = String.fromEnvironment('APPLE_REDIRECT_URI');

  /// Show the password sign-in option (the server must also allow it).
  static const passwordLogin = bool.fromEnvironment('PASSWORD_LOGIN', defaultValue: true);

  /// Demo mode: the app runs on recorded sample responses instead of a server. Never in production.
  ///   flutter run -d chrome --dart-define=DEMO=true
  static const demo = bool.fromEnvironment('DEMO') && appEnv != 'production';

  static bool get isProduction => appEnv == 'production';

  /// The component gallery and motion lab are design tools: dev and staging only.
  static bool get showDesignTools => !isProduction;
}
