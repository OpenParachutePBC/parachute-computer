import 'dart:io';
import 'package:flutter/foundation.dart';

/// Application configuration with environment-based overrides.
class AppConfig {
  /// Default server URL used as fallback throughout the app.
  /// All provider fallbacks should reference this constant instead of
  /// hardcoding 'http://localhost:1940'.
  static const String defaultServerUrl = 'http://localhost:1940';

  /// Get the server base URL based on environment and platform.
  ///
  /// Priority:
  /// 1. --dart-define=SERVER_URL (build-time override)
  /// 2. Platform-specific defaults for development
  /// 3. Production default
  static String get serverBaseUrl {
    // Check for build-time environment variable
    const String envUrl = String.fromEnvironment('SERVER_URL');
    if (envUrl.isNotEmpty) {
      return envUrl;
    }

    // Development defaults by platform
    if (kDebugMode) {
      if (Platform.isAndroid) {
        // Android emulator uses 10.0.2.2 to reach host machine
        return 'http://10.0.2.2:1940';
      } else if (Platform.isIOS) {
        // iOS simulator can use localhost
        return defaultServerUrl;
      } else {
        // Desktop (macOS, Linux, Windows) uses localhost
        return defaultServerUrl;
      }
    }

    // Production default (update when deploying)
    return 'https://api.parachute.computer';
  }
}
