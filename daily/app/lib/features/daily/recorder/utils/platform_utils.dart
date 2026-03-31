import 'dart:io';

/// Platform utility functions
///
/// Provides helper methods for platform-specific feature detection
/// and graceful degradation on unsupported platforms.
class PlatformUtils {
  /// Check if BLE is supported on current platform
  ///
  /// BLE is fully supported on iOS and Android.
  /// macOS has limited support (scanning works, but background modes differ).
  /// Web and other platforms are not supported.
  static bool get isBleSupported {
    return Platform.isIOS || Platform.isAndroid || Platform.isMacOS;
  }

  /// Check if full BLE background mode is supported
  ///
  /// Background BLE operation (when app is closed) only works on iOS and Android.
  /// macOS apps stay running when window is closed, so no special handling needed.
  static bool get isBluetoothBackgroundSupported {
    return Platform.isIOS || Platform.isAndroid;
  }

  /// Check if local notifications are supported
  ///
  /// Only iOS and Android support flutter_local_notifications.
  static bool get areNotificationsSupported {
    return Platform.isIOS || Platform.isAndroid;
  }

  /// Check if this is a mobile platform
  static bool get isMobile {
    return Platform.isIOS || Platform.isAndroid;
  }

  /// Check if this is a desktop platform
  static bool get isDesktop {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  /// Get platform name for display
  static String get platformName {
    if (Platform.isIOS) return 'iOS';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Unknown';
  }

  /// Get user-friendly message for unsupported BLE features
  static String getBluetoothUnsupportedMessage() {
    if (Platform.isMacOS) {
      return 'Omi device pairing is available on macOS, but background '
          'recording when the app is closed is not supported. Keep the app '
          'open to use your Omi device.';
    }
    return 'Omi device pairing is not supported on this platform. '
        'Please use iOS or Android for Omi device features.';
  }

  /// Check if we should show Omi device features in UI
  ///
  /// Only show on iOS and Android. macOS has BLE support but the Opus codec
  /// (needed for decoding Omi audio streams) doesn't work on macOS.
  static bool get shouldShowOmiFeatures {
    return Platform.isIOS || Platform.isAndroid;
  }
}
