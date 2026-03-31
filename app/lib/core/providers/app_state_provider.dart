import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

// computer_service.dart removed in v2 — no longer needed

/// App flavor set at compile time via --dart-define=FLAVOR=daily|client|computer
/// Defaults to 'client' if not specified
///
/// Flavors:
/// - daily: Offline journal only, no server features
/// - client: Standard app - connects to external server (default)
/// - computer: Desktop Parachute Computer (server + Docker sandboxing)
const String appFlavor = String.fromEnvironment('FLAVOR', defaultValue: 'client');

/// Whether the app was built as the Daily-only flavor
bool get isDailyOnlyFlavor => appFlavor == 'daily';

/// Whether the app was built as the Client flavor (external server)
bool get isClientFlavor => appFlavor == 'client';

/// Whether the app was built as the Computer flavor
bool get isComputerFlavor => appFlavor == 'computer';

// ============================================================================
// Server Mode (for Computer flavor)
// ============================================================================

/// How the Parachute server is run (Computer flavor only)
///
/// Currently only bareMetal is supported. Server runs directly on macOS
/// with Docker containers providing sandboxed execution.
enum ServerMode {
  /// Server runs directly on macOS
  /// Full performance, Docker containers for sandboxing
  bareMetal,
}

/// Notifier for server mode preference (Computer flavor)
class ServerModeNotifier extends AsyncNotifier<ServerMode> {
  static const _key = 'parachute_server_mode';

  @override
  Future<ServerMode> build() async {
    return ServerMode.bareMetal;
  }

  Future<void> setServerMode(ServerMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, 'bareMetal');
    state = AsyncData(mode);
  }
}

/// Server mode provider (Computer flavor only)
final serverModeProvider = AsyncNotifierProvider<ServerModeNotifier, ServerMode>(() {
  return ServerModeNotifier();
});

// ============================================================================
// Custom Computer Path (for developers)
// ============================================================================

/// Notifier for custom computer path (optional, for developers)
class CustomBasePathNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_custom_base_path';
  static const _enabledKey = 'parachute_custom_base_enabled';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabledKey) ?? false;
    if (!enabled) return null;
    return prefs.getString(_key);
  }

  Future<void> setCustomPath(String? path, {bool enabled = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (path != null && path.isNotEmpty && enabled) {
      await prefs.setString(_key, path);
      await prefs.setBool(_enabledKey, true);
      state = AsyncData(path);
    } else {
      await prefs.setBool(_enabledKey, false);
      state = const AsyncData(null);
    }
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    state = const AsyncData(null);
  }
}

/// Custom computer path provider (null if using bundled)
final customBasePathProvider = AsyncNotifierProvider<CustomBasePathNotifier, String?>(() {
  return CustomBasePathNotifier();
});

// ============================================================================
// App Mode
// ============================================================================

/// App mode — daily-only in v2
enum AppMode {
  dailyOnly,
}

/// Available tabs — daily only in v2
enum AppTab {
  daily,
}

/// Notifier for server URL with persistence
class ServerUrlNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_server_url';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  /// Validate that a URL is well-formed and uses http/https
  static bool isValidServerUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.hasScheme &&
             (uri.scheme == 'http' || uri.scheme == 'https') &&
             uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> setServerUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url != null && url.isNotEmpty) {
      // Validate URL before saving
      if (!isValidServerUrl(url)) {
        throw ArgumentError('Invalid server URL: must be a valid http:// or https:// URL');
      }
      await prefs.setString(_key, url);
      state = AsyncData(url);
    } else {
      await prefs.remove(_key);
      state = const AsyncData(null);
    }
  }
}

/// Server URL provider with notifier for updates
final serverUrlProvider = AsyncNotifierProvider<ServerUrlNotifier, String?>(() {
  return ServerUrlNotifier();
});

/// App mode based on flavor and server configuration
///
/// - Daily flavor: Always dailyOnly (Chat/Vault not available)
/// - Full flavor: Full if server configured, dailyOnly if not
final appModeProvider = Provider<AppMode>((ref) {
  // Daily-only flavor is always in daily mode regardless of server
  if (isDailyOnlyFlavor) {
    return AppMode.dailyOnly;
  }

  return AppMode.dailyOnly;
});

/// List of visible tabs — daily only in v2
final visibleTabsProvider = Provider<List<AppTab>>((ref) {
  return [AppTab.daily];
});

/// Current tab index
final currentTabIndexProvider = StateProvider<int>((ref) => 0);

/// Check if server is configured
final isServerConfiguredProvider = Provider<bool>((ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  return serverUrlAsync.when(
    data: (url) => url != null && url.isNotEmpty,
    loading: () => false,
    error: (_, _) => false,
  );
});

/// Notifier for API key with persistence via flutter_secure_storage.
///
/// Uses platform-specific encrypted storage (Keychain on iOS/macOS,
/// EncryptedSharedPreferences on Android, libsecret on Linux).
/// Automatically migrates keys from the old SharedPreferences storage.
class ApiKeyNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_api_key';
  static const _secureStorage = FlutterSecureStorage();

  @override
  Future<String?> build() async {
    // Try secure storage first
    final secureKey = await _secureStorage.read(key: _key);
    if (secureKey != null) return secureKey;

    // Migrate from SharedPreferences if present
    final prefs = await SharedPreferences.getInstance();
    final legacyStored = prefs.getString(_key);
    if (legacyStored != null) {
      String plainKey;
      try {
        plainKey = String.fromCharCodes(base64Decode(legacyStored));
      } catch (_) {
        // Unencoded legacy value
        plainKey = legacyStored;
      }
      // Migrate to secure storage and remove from SharedPreferences
      await _secureStorage.write(key: _key, value: plainKey);
      await prefs.remove(_key);
      debugPrint('[ApiKey] Migrated from SharedPreferences to secure storage');
      return plainKey;
    }

    return null;
  }

  Future<void> setApiKey(String? key) async {
    if (key != null && key.isNotEmpty) {
      await _secureStorage.write(key: _key, value: key);
      state = AsyncData(key);
    } else {
      await _secureStorage.delete(key: _key);
      state = const AsyncData(null);
    }
  }
}

/// API key provider with notifier for updates
final apiKeyProvider = AsyncNotifierProvider<ApiKeyNotifier, String?>(() {
  return ApiKeyNotifier();
});

/// Sync mode - whether to sync all files or just text
enum SyncMode {
  /// Only sync text files (markdown, configs) - faster, less bandwidth
  textOnly,
  /// Sync all files including audio and images
  full,
}

/// Notifier for sync mode preference
class SyncModeNotifier extends AsyncNotifier<SyncMode> {
  static const _key = 'parachute_sync_mode';

  @override
  Future<SyncMode> build() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return value == 'full' ? SyncMode.full : SyncMode.textOnly;
  }

  Future<void> setSyncMode(SyncMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == SyncMode.full ? 'full' : 'textOnly');
    state = AsyncData(mode);
  }
}

/// Sync mode provider
final syncModeProvider = AsyncNotifierProvider<SyncModeNotifier, SyncMode>(() {
  return SyncModeNotifier();
});

/// Notifier for onboarding completion state
class OnboardingNotifier extends AsyncNotifier<bool> {
  static const _key = 'parachute_onboarding_complete';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    state = const AsyncData(true);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    state = const AsyncData(false);
  }
}

/// Provider for onboarding completion state
final onboardingCompleteProvider = AsyncNotifierProvider<OnboardingNotifier, bool>(() {
  return OnboardingNotifier();
});

// ============================================================================
// Vault Path Configuration
// ============================================================================

/// Notifier for vault path display.
///
/// In Parachute Computer mode, the vault path is fetched from the server
/// health endpoint for display purposes only (e.g., the onboarding ready screen).
/// The vault path is no longer user-configurable or persisted to SharedPreferences.
class VaultPathNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    if (!isComputerFlavor) return null;
    return _fetchServerVaultPath();
  }

  Future<String?> _fetchServerVaultPath() async {
    // Vault path is no longer fetched from server in v2
    return null;
  }

  /// Refresh vault path from server (call after server starts).
  Future<void> refreshFromServer() async {
    if (!isComputerFlavor) return;
    final path = await _fetchServerVaultPath();
    state = AsyncData(path);
  }

}

/// Vault path provider with notifier for updates
final vaultPathProvider = AsyncNotifierProvider<VaultPathNotifier, String?>(() {
  return VaultPathNotifier();
});

/// Whether sync should be disabled because app and server share the same vault.
///
/// In Parachute Computer mode, sync is unnecessary and can cause confusion
/// because both the app and server are reading/writing the same files.
/// Instead of syncing files with ourselves, we just use direct file access.
final syncDisabledProvider = Provider<bool>((ref) {
  // Sync is disabled in Parachute Computer mode because the app and server
  // share the same filesystem
  return isComputerFlavor;
});

// ============================================================================
// App Version
// ============================================================================

/// App version info from pubspec.yaml (loaded at runtime via package_info_plus)
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// Full app version with build number (e.g., "0.2.3+1")
final appVersionFullProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
});

// ============================================================================
// Setup Reset (for testing/troubleshooting)
// ============================================================================

/// Reset all setup-related state to start fresh
///
/// This clears:
/// - Server URL (puts app back in dailyOnly mode)
/// - Server mode
/// - Vault path selection
/// - Onboarding completion flag
///
/// Does NOT clear:
/// - API key (user might want to keep this)
/// - Custom base path (developer setting)
/// - Sync mode preferences
Future<void> resetSetup(WidgetRef ref) async {
  final prefs = await SharedPreferences.getInstance();

  // Clear setup-related keys
  await prefs.remove('parachute_server_url');
  await prefs.remove('parachute_server_mode');
  await prefs.remove('parachute_onboarding_complete');

  // Invalidate providers to force reload
  ref.invalidate(serverUrlProvider);
  ref.invalidate(serverModeProvider);
  ref.invalidate(vaultPathProvider);
  ref.invalidate(onboardingCompleteProvider);
  ref.invalidate(appModeProvider);
}
