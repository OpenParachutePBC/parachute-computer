import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/base_server_service.dart';

/// App flavor set at compile time via --dart-define=FLAVOR=daily|client|computer
/// Defaults to 'client' if not specified
///
/// Flavors:
/// - daily: Offline journal only, no server features
/// - client: Standard app - connects to external server (default)
/// - computer: Desktop with bundled Lima VM (Parachute Computer)
const String appFlavor = String.fromEnvironment('FLAVOR', defaultValue: 'client');

/// Whether the app was built as the Daily-only flavor
bool get isDailyOnlyFlavor => appFlavor == 'daily';

/// Whether the app was built as the Client flavor (external server)
bool get isClientFlavor => appFlavor == 'client';

/// Whether the app was built as the Computer flavor (bundled Lima VM)
bool get isComputerFlavor => appFlavor == 'computer';

/// Whether the app should show Lima VM controls (Computer flavor only)
bool get showLimaControls => isComputerFlavor;

// ============================================================================
// Server Mode (for Computer flavor)
// ============================================================================

/// How the Parachute server is run (Computer flavor only)
///
/// - limaVM: Server runs in isolated Lima VM (more secure, recommended for shared computers)
/// - bareMetal: Server runs directly on macOS (better performance, for dedicated machines)
enum ServerMode {
  /// Server runs in isolated Lima VM
  /// Claude can only access the vault, not the host filesystem
  limaVM,

  /// Server runs directly on macOS
  /// Full performance, access to MLX, native builds
  /// Best for dedicated Parachute machines
  bareMetal,
}

/// Notifier for server mode preference (Computer flavor)
class ServerModeNotifier extends AsyncNotifier<ServerMode> {
  static const _key = 'parachute_server_mode';

  @override
  Future<ServerMode> build() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return value == 'bareMetal' ? ServerMode.bareMetal : ServerMode.limaVM;
  }

  Future<void> setServerMode(ServerMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == ServerMode.bareMetal ? 'bareMetal' : 'limaVM');
    state = AsyncData(mode);
  }
}

/// Server mode provider (Computer flavor only)
final serverModeProvider = AsyncNotifierProvider<ServerModeNotifier, ServerMode>(() {
  return ServerModeNotifier();
});

/// Whether the current server mode is Lima VM
final isLimaVMModeProvider = Provider<bool>((ref) {
  if (!isComputerFlavor) return false;
  final modeAsync = ref.watch(serverModeProvider);
  return modeAsync.valueOrNull == ServerMode.limaVM;
});

/// Whether the current server mode is bare metal
final isBareMetalModeProvider = Provider<bool>((ref) {
  if (!isComputerFlavor) return false;
  final modeAsync = ref.watch(serverModeProvider);
  return modeAsync.valueOrNull == ServerMode.bareMetal;
});

// ============================================================================
// Custom Base Server Path (for developers)
// ============================================================================

/// Notifier for custom base server path (optional, for developers)
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

/// Custom base server path provider (null if using bundled)
final customBasePathProvider = AsyncNotifierProvider<CustomBasePathNotifier, String?>(() {
  return CustomBasePathNotifier();
});

// ============================================================================
// App Mode
// ============================================================================

/// App mode determines which features are available
enum AppMode {
  /// Daily only - no server configured, works offline
  dailyOnly,

  /// Full mode - server configured, all features available
  full,
}

/// Available tabs in the app
enum AppTab {
  chat,
  daily,
  vault,
  brain,
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

  // Full flavor checks server configuration
  final serverUrlAsync = ref.watch(serverUrlProvider);

  return serverUrlAsync.when(
    data: (url) => url != null && url.isNotEmpty ? AppMode.full : AppMode.dailyOnly,
    loading: () => AppMode.dailyOnly,
    error: (_, _) => AppMode.dailyOnly,
  );
});

/// List of visible tabs based on app mode
final visibleTabsProvider = Provider<List<AppTab>>((ref) {
  final mode = ref.watch(appModeProvider);

  return switch (mode) {
    AppMode.dailyOnly => [AppTab.daily],
    AppMode.full => [AppTab.chat, AppTab.daily, AppTab.vault, AppTab.brain],
  };
});

/// Current tab index (persists across rebuilds)
final currentTabIndexProvider = StateProvider<int>((ref) {
  final visibleTabs = ref.watch(visibleTabsProvider);
  // Default to Daily (center tab)
  return visibleTabs.indexOf(AppTab.daily).clamp(0, visibleTabs.length - 1);
});

/// Check if server is configured
final isServerConfiguredProvider = Provider<bool>((ref) {
  return ref.watch(appModeProvider) == AppMode.full;
});

/// Notifier for API key with persistence
///
/// SECURITY NOTE: API keys are currently stored in SharedPreferences.
/// This is NOT secure - SharedPreferences is unencrypted plaintext storage.
/// TODO: Migrate to flutter_secure_storage for encrypted storage.
/// For now, basic obfuscation is applied as a temporary measure.
class ApiKeyNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_api_key';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    if (stored == null) return null;
    // Deobfuscate from base64
    try {
      return String.fromCharCodes(base64Decode(stored));
    } catch (_) {
      // If decoding fails, assume it's unencoded (migration)
      return stored;
    }
  }

  Future<void> setApiKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    if (key != null && key.isNotEmpty) {
      // Basic obfuscation via base64 (NOT encryption, just prevents casual viewing)
      final encoded = base64Encode(key.codeUnits);
      await prefs.setString(_key, encoded);
      state = AsyncData(key);
    } else {
      await prefs.remove(_key);
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

/// Notifier for vault path with persistence
///
/// The vault is where all Parachute data lives: journals, chats, files.
/// Common locations:
/// - ~/Parachute: Dedicated vault folder (recommended)
/// - ~: Home directory as vault (for advanced users)
/// - Custom path: User-specified location
///
/// In Parachute Computer mode (bare metal or Lima VM), the vault path
/// is fetched from the server to ensure app and server use the same location.
/// This eliminates the need for sync - both read/write the same files.
class VaultPathNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_vault_path';
  static const _serverVaultKey = 'parachute_server_vault_path';

  @override
  Future<String?> build() async {
    // In Parachute Computer mode, try to get vault path from server
    if (isComputerFlavor) {
      final serverVaultPath = await _fetchServerVaultPath();
      if (serverVaultPath != null) {
        debugPrint('[VaultPathNotifier] Using server vault path: $serverVaultPath');
        return serverVaultPath;
      }
    }

    // Fall back to locally stored path
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  /// Fetch vault path from the running server
  Future<String?> _fetchServerVaultPath() async {
    try {
      final service = BaseServerService();
      final serverVaultPath = await service.getServerVaultPath();
      if (serverVaultPath != null && serverVaultPath.isNotEmpty) {
        // Cache the server vault path for offline reference
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_serverVaultKey, serverVaultPath);
        return serverVaultPath;
      }
    } catch (e) {
      debugPrint('[VaultPathNotifier] Error fetching server vault path: $e');
    }

    // Try cached server vault path if server unreachable
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverVaultKey);
  }

  /// Refresh vault path from server (call after server starts)
  Future<void> refreshFromServer() async {
    if (!isComputerFlavor) return;

    final serverVaultPath = await _fetchServerVaultPath();
    if (serverVaultPath != null) {
      debugPrint('[VaultPathNotifier] Refreshed server vault path: $serverVaultPath');
      state = AsyncData(serverVaultPath);
    }
  }

  Future<void> setVaultPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path != null && path.isNotEmpty) {
      await prefs.setString(_key, path);
      state = AsyncData(path);
    } else {
      await prefs.remove(_key);
      state = const AsyncData(null);
    }
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
  // Sync is disabled in Parachute Computer mode (both Lima VM and bare metal)
  // because the app and server share the same filesystem
  return isComputerFlavor;
});

/// Default vault path options
class VaultPathOption {
  final String path;
  final String label;
  final String description;

  const VaultPathOption({
    required this.path,
    required this.label,
    required this.description,
  });
}

/// Get the default vault path (~)
/// On desktop, defaults to home directory for the "operating at root" experience.
String getDefaultVaultPath() {
  final home = const String.fromEnvironment('HOME', defaultValue: '');
  if (home.isNotEmpty) return home;
  // Fallback for platforms where HOME isn't set at compile time
  return '~';
}

// ============================================================================
// Model Preference
// ============================================================================

/// Available Claude models for chat
enum ClaudeModel {
  sonnet('Sonnet', 'sonnet'),
  opus('Opus', 'opus'),
  haiku('Haiku', 'haiku');

  final String displayName;
  final String apiValue;

  const ClaudeModel(this.displayName, this.apiValue);

  static ClaudeModel fromApiValue(String value) {
    return ClaudeModel.values.firstWhere(
      (m) => m.apiValue == value,
      orElse: () => ClaudeModel.sonnet,
    );
  }
}

/// Notifier for model preference with persistence
class ModelPreferenceNotifier extends AsyncNotifier<ClaudeModel> {
  static const _key = 'parachute_model_preference';

  @override
  Future<ClaudeModel> build() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    if (value == null) return ClaudeModel.sonnet;
    return ClaudeModel.fromApiValue(value);
  }

  Future<void> setModel(ClaudeModel model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, model.apiValue);
    state = AsyncData(model);
  }
}

/// Model preference provider
final modelPreferenceProvider = AsyncNotifierProvider<ModelPreferenceNotifier, ClaudeModel>(() {
  return ModelPreferenceNotifier();
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
/// - Server mode (Lima vs Bare Metal choice)
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
  await prefs.remove('parachute_vault_path');
  await prefs.remove('parachute_onboarding_complete');

  // Invalidate providers to force reload
  ref.invalidate(serverUrlProvider);
  ref.invalidate(serverModeProvider);
  ref.invalidate(vaultPathProvider);
  ref.invalidate(onboardingCompleteProvider);
  ref.invalidate(appModeProvider);
}
