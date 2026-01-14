import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// App mode based on server configuration
final appModeProvider = Provider<AppMode>((ref) {
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
