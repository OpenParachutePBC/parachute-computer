import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App flavor set at compile time via --dart-define=FLAVOR=daily|mobile|computer|full
/// Defaults to 'full' if not specified
///
/// Flavors:
/// - daily: Offline journal only, no server features
/// - mobile: For phones/tablets, connects to remote server
/// - computer: Desktop with bundled Lima VM (Parachute Computer)
/// - full: Development/testing, all features configurable
const String appFlavor = String.fromEnvironment('FLAVOR', defaultValue: 'full');

/// Whether the app was built as the Daily-only flavor
bool get isDailyOnlyFlavor => appFlavor == 'daily';

/// Whether the app was built as the Mobile flavor (remote server)
bool get isMobileFlavor => appFlavor == 'mobile';

/// Whether the app was built as the Computer flavor (bundled Lima VM)
bool get isComputerFlavor => appFlavor == 'computer';

/// Whether the app should show Lima VM controls
/// (Computer flavor always, Full flavor on desktop)
bool get showLimaControls => isComputerFlavor || appFlavor == 'full';

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
}

/// Notifier for server URL with persistence
class ServerUrlNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_server_url';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setServerUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url != null && url.isNotEmpty) {
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
    AppMode.full => [AppTab.chat, AppTab.daily, AppTab.vault],
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
class ApiKeyNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_api_key';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> setApiKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    if (key != null && key.isNotEmpty) {
      await prefs.setString(_key, key);
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
