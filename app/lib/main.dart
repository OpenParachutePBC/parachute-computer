import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as flutter_blue_plus;
import 'package:opus_dart/opus_dart.dart' as opus_dart;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'core/theme/app_theme.dart';
import 'core/theme/design_tokens.dart';
import 'core/providers/app_state_provider.dart';
import 'core/providers/model_download_provider.dart';
import 'core/providers/server_providers.dart';
import 'core/providers/sync_provider.dart';
import 'core/services/logging_service.dart';
import 'core/services/model_download_service.dart';
import 'core/widgets/model_download_banner.dart';
import 'features/daily/home/screens/home_screen.dart';
import 'features/chat/screens/chat_hub_screen.dart';
import 'features/chat/services/background_stream_manager.dart';
import 'features/chat/widgets/message_bubble.dart' show currentlyRenderingMarkdown, markMarkdownAsFailed;
import 'features/vault/screens/vault_browser_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/onboarding/screens/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging
  await logger.initialize();

  logger.info('Main', 'Starting Parachute app...');

  // Initialize background services
  await _initializeServices();

  // Set up global error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    final errorString = details.toString().toLowerCase();

    // Catch flutter_markdown builder errors and trigger fallback to plain text
    if (errorString.contains('_inlines') ||
        errorString.contains('flutter_markdown') ||
        (errorString.contains('builder.dart') && errorString.contains('assertion'))) {
      final currentMarkdown = currentlyRenderingMarkdown;
      if (currentMarkdown != null) {
        markMarkdownAsFailed(currentMarkdown.hashCode);
        return; // Don't present - handled by error boundary
      }
    }

    FlutterError.presentError(details);
    logger.captureException(
      details.exception,
      stackTrace: details.stack,
      tag: 'FlutterError',
      extras: {
        'library': details.library ?? 'unknown',
        'context': details.context?.toString() ?? 'unknown',
      },
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logger.captureException(error, stackTrace: stack, tag: 'PlatformDispatcher');
    return true;
  };

  // Create provider container for early initialization
  final container = ProviderContainer();

  // Initialize bundled server on desktop platforms
  // This checks if the app has a bundled server binary and starts it
  // EXCEPT for "computer" flavor which uses Lima VM for the server
  // In "full" flavor, we also skip if Lima VM is running (dev testing VM mode)
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    if (isComputerFlavor) {
      debugPrint('[Parachute] Computer flavor - server managed by Lima VM');
    } else {
      // Check if Lima VM is running (for dev testing with VM)
      final limaRunning = await _isLimaVMRunning();
      if (limaRunning) {
        debugPrint('[Parachute] Lima VM detected - skipping bundled server');
      } else {
        debugPrint('[Parachute] Checking for bundled server...');
        await initializeBundledServer(container);
      }
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ParachuteApp(),
    ),
  );
}

/// Initialize services that should start before app renders
Future<void> _initializeServices() async {
  // Initialize Opus codec for Omi BLE audio decoding (iOS/Android only)
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      debugPrint('[Parachute] Initializing Opus codec...');
      final opusLib = await opus_flutter.load();
      opus_dart.initOpus(opusLib);
      debugPrint('[Parachute] Opus codec initialized');
    } catch (e) {
      debugPrint('[Parachute] Failed to initialize Opus codec: $e');
    }
  }

  // Disable verbose FlutterBluePlus logs
  flutter_blue_plus.FlutterBluePlus.setLogLevel(
    flutter_blue_plus.LogLevel.none,
    color: false,
  );

  // Initialize Flutter Gemma for on-device AI (embeddings, title generation)
  try {
    debugPrint('[Parachute] Initializing FlutterGemma...');
    await FlutterGemma.initialize();
    debugPrint('[Parachute] FlutterGemma initialized');
  } catch (e) {
    debugPrint('[Parachute] Failed to initialize FlutterGemma: $e');
  }

  // Initialize transcription service in background (don't await)
  _initializeTranscription();
}

/// Check if Lima VM "parachute" is running
Future<bool> _isLimaVMRunning() async {
  if (!Platform.isMacOS) return false;

  try {
    final result = await Process.run('limactl', ['list', '--format', '{{.Name}}:{{.Status}}']);
    if (result.exitCode == 0) {
      final output = result.stdout.toString();
      for (final line in output.split('\n')) {
        if (line.startsWith('parachute:') && line.contains('Running')) {
          return true;
        }
      }
    }
  } catch (e) {
    debugPrint('[Parachute] Error checking Lima VM: $e');
  }
  return false;
}

/// Initialize transcription model download in background
///
/// On Android, this downloads the Sherpa-ONNX Parakeet model (~465MB)
/// The download continues in the background and the app remains usable.
void _initializeTranscription() async {
  // Only needed on Android - iOS/macOS use FluidAudio which handles its own models
  if (!Platform.isAndroid) {
    debugPrint('[Parachute] Skipping model download (not Android)');
    return;
  }

  try {
    debugPrint('[Parachute] Checking transcription model status...');
    final downloadService = ModelDownloadService();

    // Directly check if models are ready
    final modelsReady = await downloadService.areModelsReady();
    debugPrint('[Parachute] areModelsReady() returned: $modelsReady');

    await downloadService.initialize();
    debugPrint('[Parachute] After initialize, state.isReady: ${downloadService.currentState.isReady}, status: ${downloadService.currentState.status}');

    if (downloadService.currentState.isReady) {
      debugPrint('[Parachute] Transcription models already downloaded');
      return;
    }

    debugPrint('[Parachute] Starting transcription model download in background...');
    // Start download in background - don't await
    downloadService.startDownload().then((_) {
      debugPrint('[Parachute] Transcription model download complete');
    }).catchError((e) {
      debugPrint('[Parachute] Transcription model download failed: $e');
    });
  } catch (e) {
    debugPrint('[Parachute] Transcription init error: $e');
  }
}

class ParachuteApp extends StatelessWidget {
  const ParachuteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: isDailyOnlyFlavor ? 'Parachute Daily' : 'Parachute',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const MainShell(),
      routes: {
        '/settings': (context) => const SettingsScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
      },
    );
  }
}

/// Main shell - handles onboarding and tab navigation
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  @override
  Widget build(BuildContext context) {
    final onboardingCompleteAsync = ref.watch(onboardingCompleteProvider);

    return onboardingCompleteAsync.when(
      data: (isComplete) {
        if (!isComplete) {
          return const OnboardingScreen();
        }
        return const _TabShell();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const _TabShell(), // On error, just show the app
    );
  }
}

/// Global navigator keys for each tab (for nested navigation)
final chatNavigatorKey = GlobalKey<NavigatorState>();
final dailyNavigatorKey = GlobalKey<NavigatorState>();
final vaultNavigatorKey = GlobalKey<NavigatorState>();

/// Tab navigation shell - Daily center, Chat/Vault conditional
class _TabShell extends ConsumerStatefulWidget {
  const _TabShell();

  @override
  ConsumerState<_TabShell> createState() => _TabShellState();
}

class _TabShellState extends ConsumerState<_TabShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Eagerly initialize sync provider so it's ready when journal entries are created
    // Access the notifier directly - it handles its own async server check internally
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[MainShell] Eagerly initializing sync provider');
      ref.read(syncProvider.notifier);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle sync lifecycle
    final syncAvailable = ref.read(syncAvailableProvider);
    if (syncAvailable) {
      final syncNotifier = ref.read(syncProvider.notifier);
      switch (state) {
        case AppLifecycleState.resumed:
          syncNotifier.onAppResumed();
          break;
        case AppLifecycleState.paused:
        case AppLifecycleState.inactive:
          syncNotifier.onAppPaused();
          break;
        default:
          break;
      }
    }

    // Clean up background streams when app is detached/terminated
    // This prevents memory leaks from orphaned stream controllers
    if (state == AppLifecycleState.detached) {
      debugPrint('[MainShell] App detached - cleaning up background streams');
      BackgroundStreamManager.instance.cancelAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appMode = ref.watch(appModeProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine visible tabs based on app mode
    final showAllTabs = appMode == AppMode.full;

    // Build tab destinations
    final destinations = <NavigationDestination>[];
    final screens = <Widget>[];

    if (showAllTabs) {
      destinations.add(NavigationDestination(
        icon: Icon(
          Icons.chat_bubble_outline,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
        selectedIcon: Icon(
          Icons.chat_bubble,
          color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
        ),
        label: 'Chat',
      ));
      // Chat tab with nested navigator
      screens.add(Navigator(
        key: chatNavigatorKey,
        onGenerateRoute: (settings) {
          return MaterialPageRoute(
            builder: (context) => const ChatHubScreen(),
            settings: settings,
          );
        },
      ));
    }

    // Daily is always in the middle (or only tab when server not configured)
    destinations.add(NavigationDestination(
      icon: Icon(
        Icons.today_outlined,
        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
      ),
      selectedIcon: Icon(
        Icons.today,
        color: isDark ? BrandColors.nightForest : BrandColors.forest,
      ),
      label: 'Daily',
    ));
    // Daily tab with nested navigator
    screens.add(Navigator(
      key: dailyNavigatorKey,
      onGenerateRoute: (settings) {
        return MaterialPageRoute(
          builder: (context) => const HomeScreen(),
          settings: settings,
        );
      },
    ));

    if (showAllTabs) {
      destinations.add(NavigationDestination(
        icon: Icon(
          Icons.folder_outlined,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
        selectedIcon: Icon(
          Icons.folder,
          color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
        ),
        label: 'Vault',
      ));
      // Vault tab with nested navigator
      screens.add(Navigator(
        key: vaultNavigatorKey,
        onGenerateRoute: (settings) {
          return MaterialPageRoute(
            builder: (context) => const VaultBrowserScreen(),
            settings: settings,
          );
        },
      ));
    }

    // Current tab index - Daily is center
    final currentIndex = ref.watch(currentTabIndexProvider);
    // Clamp index to valid range when tabs change
    final safeIndex = currentIndex.clamp(0, screens.length - 1);

    // Only show navigation bar if there are multiple tabs
    final showNavBar = screens.length > 1;

    return Scaffold(
      body: Column(
        children: [
          // Model download progress banner (only shows during download on Android)
          const ModelDownloadBanner(),
          // Main content
          Expanded(
            child: IndexedStack(
              index: safeIndex,
              children: screens,
            ),
          ),
        ],
      ),
      bottomNavigationBar: showNavBar
          ? NavigationBar(
              selectedIndex: safeIndex,
              onDestinationSelected: (index) {
                ref.read(currentTabIndexProvider.notifier).state = index;
              },
              backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
              indicatorColor: isDark
                  ? BrandColors.nightTurquoise.withValues(alpha: 0.2)
                  : BrandColors.turquoise.withValues(alpha: 0.2),
              destinations: destinations,
            )
          : null,
    );
  }
}

/// Placeholder screen for development
class _PlaceholderScreen extends StatelessWidget {
  final String title;
  final IconData icon;

  const _PlaceholderScreen({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 64,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: 16),
            Text(
              '$title Screen',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Coming soon...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
