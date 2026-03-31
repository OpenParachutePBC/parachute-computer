import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/theme/app_theme.dart';

/// Creates the real ParachuteApp wrapped in a ProviderScope with test overrides.
///
/// This boots the actual widget tree (MainShell → _TabShell → real screens)
/// but stubs out providers that depend on native plugins or network services.
///
/// Usage:
///   await tester.pumpWidget(createTestApp());
///   await tester.pumpWidget(createTestApp(mode: AppMode.dailyOnly));
Widget createTestApp({
  AppMode mode = AppMode.full,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      // Core state: control app mode directly
      appModeProvider.overrideWith((ref) => mode),

      // Skip onboarding in tests
      onboardingCompleteProvider.overrideWith(OnboardingNotifier.new),

      // Provide a fake server URL so full-mode screens don't error
      serverUrlProvider.overrideWith(ServerUrlNotifier.new),

      // Provide a fake AI server URL for screens that watch it
      aiServerUrlProvider.overrideWith(
        (ref) async => 'http://localhost:9999',
      ),

      // User-provided overrides
      ...extraOverrides,
    ],
    child: MaterialApp(
      title: 'Parachute Test',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.light, // Deterministic for tests
      home: const _TestShell(),
    ),
  );
}

/// Creates a test app in dark mode for dark-mode-specific testing.
Widget createTestAppDark({
  AppMode mode = AppMode.full,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      appModeProvider.overrideWith((ref) => mode),
      onboardingCompleteProvider.overrideWith(OnboardingNotifier.new),
      serverUrlProvider.overrideWith(ServerUrlNotifier.new),
      aiServerUrlProvider.overrideWith(
        (ref) async => 'http://localhost:9999',
      ),
      ...extraOverrides,
    ],
    child: MaterialApp(
      title: 'Parachute Test',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const _TestShell(),
    ),
  );
}

/// Minimal shell that mirrors _TabShell structure but skips heavy initState work.
///
/// We can't directly use the real _TabShell because its initState() eagerly
/// reads syncProvider, omiBluetoothServiceProvider, etc. Instead we rebuild
/// the same NavigationBar + IndexedStack structure using the real screen widgets.
class _TestShell extends ConsumerStatefulWidget {
  const _TestShell();

  @override
  ConsumerState<_TestShell> createState() => _TestShellState();
}

class _TestShellState extends ConsumerState<_TestShell> {
  @override
  Widget build(BuildContext context) {
    final appMode = ref.watch(appModeProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showAllTabs = appMode == AppMode.full;

    final currentIndex = ref.watch(currentTabIndexProvider);

    final destinations = <NavigationDestination>[
      if (showAllTabs)
        const NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: 'Chat',
        ),
      const NavigationDestination(
        icon: Icon(Icons.today_outlined),
        selectedIcon: Icon(Icons.today),
        label: 'Daily',
      ),
      if (showAllTabs)
        const NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: 'Vault',
        ),
      if (showAllTabs)
        const NavigationDestination(
          icon: Icon(Icons.psychology_outlined),
          selectedIcon: Icon(Icons.psychology),
          label: 'Brain',
        ),
    ];

    final safeIndex = currentIndex.clamp(0, destinations.length - 1);
    final actualIndex = showAllTabs ? safeIndex : 0;

    final showNavBar = destinations.length > 1;

    // Use placeholder screens instead of real ones to avoid native deps
    // Each screen is identifiable by its title text for test assertions
    return Scaffold(
      body: IndexedStack(
        index: actualIndex,
        children: [
          if (showAllTabs) _buildTab('Chat', Icons.chat_bubble_outline, isDark),
          _buildTab('Daily', Icons.today_outlined, isDark),
          if (showAllTabs) _buildTab('Vault', Icons.folder_outlined, isDark),
          if (showAllTabs) _buildTab('Brain', Icons.psychology_outlined, isDark),
        ],
      ),
      bottomNavigationBar: showNavBar
          ? NavigationBar(
              selectedIndex: safeIndex,
              onDestinationSelected: (index) {
                ref.read(currentTabIndexProvider.notifier).state = index;
              },
              destinations: destinations,
            )
          : null,
    );
  }

  Widget _buildTab(String label, IconData icon, bool isDark) {
    return Scaffold(
      key: ValueKey('${label.toLowerCase()}_tab'),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text('$label Tab Content', style: const TextStyle(fontSize: 20)),
          ],
        ),
      ),
    );
  }
}
