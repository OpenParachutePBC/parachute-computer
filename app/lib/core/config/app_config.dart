import 'dart:io';
import 'package:flutter/foundation.dart';

/// Application configuration with environment-based overrides.
class AppConfig {
  /// Get the server base URL based on environment and platform.
  ///
  /// Priority:
  /// 1. --dart-define=SERVER_URL (build-time override)
  /// 2. Platform-specific defaults for development
  /// 3. Production default
  static String get serverBaseUrl {
    // Check for build-time environment variable
    const String? envUrl = String.fromEnvironment('SERVER_URL');
    if (envUrl != null && envUrl.isNotEmpty) {
      return envUrl;
    }

    // Development defaults by platform
    if (kDebugMode) {
      if (Platform.isAndroid) {
        // Android emulator uses 10.0.2.2 to reach host machine
        return 'http://10.0.2.2:3333';
      } else if (Platform.isIOS) {
        // iOS simulator can use localhost
        return 'http://localhost:3333';
      } else {
        // Desktop (macOS, Linux, Windows) uses localhost
        return 'http://localhost:3333';
      }
    }

    // Production default (update when deploying)
    return 'https://api.parachute.computer';
  }
}
