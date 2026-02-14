import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as flutter_blue_plus;
import 'package:opus_dart/opus_dart.dart' as opus_dart;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marionette_flutter/marionette_flutter.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/design_tokens.dart';
import 'core/providers/app_state_provider.dart';
import 'core/providers/app_events_provider.dart';
import 'core/providers/model_download_provider.dart';
import 'core/providers/server_providers.dart';
import 'core/providers/sync_provider.dart';
import 'core/providers/core_service_providers.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/logging_service.dart';
import 'core/services/model_download_service.dart';
import 'core/widgets/model_download_banner.dart';
import 'features/daily/home/screens/home_screen.dart';
import 'features/daily/recorder/providers/omi_providers.dart';
import 'features/chat/screens/chat_hub_screen.dart';
import 'features/chat/screens/chat_shell.dart';
import 'features/chat/screens/chat_screen.dart';
import 'features/chat/providers/chat_providers.dart';
import 'features/chat/widgets/message_bubble.dart' show currentlyRenderingMarkdown, markMarkdownAsFailed;
import 'features/daily/journal/providers/journal_providers.dart';
import 'features/vault/screens/vault_browser_screen.dart';
import 'features/vault/screens/remote_files_screen.dart';
import 'features/brain/screens/brain_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/onboarding/screens/onboarding_screen.dart';

void main() async {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  // Create provider container for early initialization
  final container = ProviderContainer();

  // Initialize global services (logging, etc.)
  await initializeGlobalServices(container);

  logger.info('Main', 'Starting Parachute app...');

  // Initialize background services
  await _initializeServices();

  // Set up global error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    final errorString = details.toString().toLowerCase();

    // Suppress known macOS Flutter bug: duplicate KeyDownEvent without KeyUpEvent
    // https://github.com/flutter/flutter/issues/139437
    if (errorString.contains('keydownevent') &&
        errorString.contains('physical key is already pressed')) {
      return;
    }

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

  // Initialize deep link service
  final deepLinkService = container.read(deepLinkServiceProvider);
  await deepLinkService.initialize();

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
      final opusLib = await opus_flutter.load();
      opus_dart.initOpus(opusLib);
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
    await FlutterGemma.initialize();
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
  if (!Platform.isAndroid) return;

  try {
    final downloadService = ModelDownloadService();
    await downloadService.initialize();

    if (downloadService.currentState.isReady) return;

    // Start download in background - don't await
    downloadService.startDownload().catchError((e) {
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

/// Tab navigation shell - Daily center, Chat/Vault conditional
class _TabShell extends ConsumerStatefulWidget {
  const _TabShell();

  @override
  ConsumerState<_TabShell> createState() => _TabShellState();
}

class _TabShellState extends ConsumerState<_TabShell> with WidgetsBindingObserver {
  /// Navigator keys are instance variables to avoid GlobalKey reuse issues
  /// when tabs are conditionally shown/hidden
  final GlobalKey<NavigatorState> _chatNavigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _dailyNavigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _vaultNavigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> _brainNavigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Eagerly initialize providers that need to start early
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Sync provider - ready when journal entries are created
      ref.read(syncProvider.notifier);

      // Omi services - Bluetooth for connection, Capture for recording
      // Only on mobile platforms where BLE is supported
      if (Platform.isAndroid || Platform.isIOS) {
        ref.read(omiBluetoothServiceProvider);
        // Read capture service after a delay to avoid circular dependency
        // The capture service sets up its own connection listener
        Future.delayed(const Duration(milliseconds: 100), () {
          ref.read(omiCaptureServiceProvider);
        });
      }

    });
  }

  /// Handle a pending chat prompt by navigating to ChatScreen
  void _handlePendingChatPrompt(PendingChatPrompt prompt) {
    // Security: Only log message preview (first 50 chars) to avoid leaking sensitive content
    debugPrint('[TabShell] Handling pending chat prompt: session=${prompt.sessionId}, agentType=${prompt.agentType}, agentPath=${prompt.agentPath}, message preview=${prompt.message.substring(0, prompt.message.length.clamp(0, 50))}${prompt.message.length > 50 ? "..." : ""}');

    // Clear the pending prompt immediately to prevent re-triggering
    ref.read(pendingChatPromptProvider.notifier).state = null;

    // Switch to chat tab
    final visibleTabs = ref.read(visibleTabsProvider);
    final chatTabIndex = visibleTabs.indexOf(AppTab.chat);
    debugPrint('[TabShell] Chat tab index: $chatTabIndex, visible tabs: $visibleTabs');
    if (chatTabIndex >= 0) {
      ref.read(currentTabIndexProvider.notifier).state = chatTabIndex;
    }

    // Set up the session
    if (prompt.sessionId != null) {
      // Existing session
      debugPrint('[TabShell] Switching to existing session: ${prompt.sessionId}');
      ref.read(switchSessionProvider)(prompt.sessionId!);
    } else {
      // New chat
      debugPrint('[TabShell] Starting new chat');
      ref.read(newChatProvider)();
    }

    // Navigate to ChatScreen with the message pre-filled
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('[TabShell] Post-frame callback - pushing ChatScreen');
      debugPrint('[TabShell] _chatNavigatorKey.currentState: ${_chatNavigatorKey.currentState}');

      // Pop to root first to avoid stacking multiple ChatScreens
      _chatNavigatorKey.currentState?.popUntil((route) => route.isFirst);

      // Then push the new ChatScreen
      final pushed = _chatNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            initialMessage: prompt.message,
            agentType: prompt.agentType,
            agentPath: prompt.agentPath,
          ),
        ),
      );
      debugPrint('[TabShell] Push result: $pushed');
    });
  }

  /// Handle a deep link target by navigating appropriately
  void _handleDeepLink(DeepLinkTarget target) {
    debugPrint('[TabShell] Handling deep link: $target');

    final visibleTabs = ref.read(visibleTabsProvider);

    // Handle tab navigation
    if (target.tab != null) {
      final tabIndex = switch (target.tab) {
        'chat' => visibleTabs.indexOf(AppTab.chat),
        'daily' => visibleTabs.indexOf(AppTab.daily),
        'vault' => visibleTabs.indexOf(AppTab.vault),
        'brain' => visibleTabs.indexOf(AppTab.brain),
        'settings' => -1, // Settings is a route, not a tab
        _ => -1,
      };

      if (target.tab == 'settings') {
        // Navigate to settings screen
        Navigator.of(context).pushNamed('/settings');
        return;
      }

      if (tabIndex >= 0) {
        ref.read(currentTabIndexProvider.notifier).state = tabIndex;

        // Handle additional navigation within the tab
        if (target.tab == 'chat') {
          _handleChatDeepLink(target);
        } else if (target.tab == 'daily') {
          _handleDailyDeepLink(target);
        } else if (target.tab == 'vault') {
          _handleVaultDeepLink(target);
        }
      }
    }
  }

  /// Handle chat-specific deep links
  void _handleChatDeepLink(DeepLinkTarget target) {
    if (target.isNewChat) {
      debugPrint('[TabShell] New chat deep link - prompt: ${target.prompt}, context: ${target.context}, autoSend: ${target.autoSend}');

      // Start a new chat
      ref.read(newChatProvider)();

      // Navigate to ChatScreen with the deep link parameters
      // Use Navigator from the chat tab's context (via global key)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _chatNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              initialMessage: target.prompt,
              autoRun: target.autoSend,
              autoRunMessage: target.autoSend ? target.prompt : null,
              agentType: target.agentType,
            ),
          ),
        );
      });
    } else if (target.sessionId != null) {
      // Security: Only log prompt presence/length, not content
      debugPrint('[TabShell] Open session deep link - session: ${target.sessionId}, message: ${target.messageIndex}, hasPrompt: ${target.prompt != null}, autoSend: ${target.autoSend}');

      // Switch to the session
      ref.read(switchSessionProvider)(target.sessionId!);

      // Navigate to ChatScreen with optional message to send
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _chatNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              initialMessage: target.prompt,
              autoRun: target.autoSend,
              autoRunMessage: target.autoSend ? target.prompt : null,
            ),
          ),
        );
      });

      // Store message index for scrolling (ChatScreen can read this)
      if (target.messageIndex != null) {
        ref.read(pendingDeepLinkProvider.notifier).state = target;
      }
    }
  }

  /// Handle daily-specific deep links
  void _handleDailyDeepLink(DeepLinkTarget target) {
    if (target.date != null) {
      debugPrint('[TabShell] Daily date deep link: ${target.date}');

      // Parse the date string (format: YYYY-MM-DD)
      final parts = target.date!.split('-');
      if (parts.length == 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);

        if (year != null && month != null && day != null) {
          final date = DateTime(year, month, day);
          ref.read(selectedJournalDateProvider.notifier).state = date;
        }
      }
    } else if (target.entryId != null) {
      debugPrint('[TabShell] Daily entry deep link: ${target.entryId}');
      // Store for the journal screen to handle scrolling to specific entry
      ref.read(pendingDeepLinkProvider.notifier).state = target;
    }
  }

  /// Handle vault-specific deep links
  void _handleVaultDeepLink(DeepLinkTarget target) {
    if (target.path != null) {
      debugPrint('[TabShell] Vault path deep link: ${target.path}');

      // Set the remote file browser path
      ref.read(remoteCurrentPathProvider.notifier).state = target.path!;
    }
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

    // Handle Omi auto-reconnect on app resume
    if (state == AppLifecycleState.resumed && (Platform.isAndroid || Platform.isIOS)) {
      final bluetoothService = ref.read(omiBluetoothServiceProvider);
      if (!bluetoothService.isConnected) {
        _attemptOmiAutoReconnect();
      }
    }

    // Clean up background streams when app is detached/terminated
    if (state == AppLifecycleState.detached) {
      ref.read(backgroundStreamManagerProvider).cancelAll();
    }
  }

  /// Attempt to auto-reconnect to last paired Omi device
  Future<void> _attemptOmiAutoReconnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoReconnectEnabled = prefs.getBool('omi_auto_reconnect_enabled') ?? true;
      if (!autoReconnectEnabled) return;

      final deviceId = prefs.getString('omi_last_paired_device_id');
      if (deviceId == null || deviceId.isEmpty) return;

      final bluetoothService = ref.read(omiBluetoothServiceProvider);
      final connection = await bluetoothService.reconnectToDevice(
        deviceId,
        onConnectionStateChanged: (id, state) {},
      );

      if (connection != null) {
        final captureService = ref.read(omiCaptureServiceProvider);
        await captureService.startListening();
      }
    } catch (e) {
      debugPrint('[MainShell] Omi auto-reconnect error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for pending chat prompts (legacy support)
    // This MUST be in build() for ref.listen to work properly
    ref.listen<PendingChatPrompt?>(pendingChatPromptProvider, (previous, next) {
      debugPrint('[TabShell] pendingChatPromptProvider changed: previous=$previous, next=$next');
      if (next != null) {
        _handlePendingChatPrompt(next);
      }
    });

    // Listen for send to chat events (cross-feature communication)
    ref.listen(sendToChatEventProvider, (previous, next) {
      debugPrint('[TabShell] sendToChatEventProvider changed: previous=$previous, next=$next');
      if (next != null) {
        // Convert SendToChatEvent to PendingChatPrompt format
        final prompt = PendingChatPrompt(
          message: next.formattedMessage,
          sessionId: next.sessionId,
          agentType: next.agentType,
          agentPath: next.agentPath,
        );
        _handlePendingChatPrompt(prompt);
        // Clear the event
        ref.read(sendToChatEventProvider.notifier).state = null;
      }
    });

    // Listen for deep links (must be in build() for ref.listen)
    ref.listen<AsyncValue<DeepLinkTarget>>(deepLinkStreamProvider, (previous, next) {
      next.whenData((target) {
        _handleDeepLink(target);
      });
    });

    final appMode = ref.watch(appModeProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Determine visible tabs based on app mode
    final showAllTabs = appMode == AppMode.full;

    // Current tab index
    final currentIndex = ref.watch(currentTabIndexProvider);

    // Build navigation destinations based on mode
    final destinations = <NavigationDestination>[
      if (showAllTabs)
        NavigationDestination(
          icon: Icon(
            Icons.chat_bubble_outline,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          selectedIcon: Icon(
            Icons.chat_bubble,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          label: 'Chat',
        ),
      NavigationDestination(
        icon: Icon(
          Icons.today_outlined,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
        selectedIcon: Icon(
          Icons.today,
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
        ),
        label: 'Daily',
      ),
      if (showAllTabs)
        NavigationDestination(
          icon: Icon(
            Icons.folder_outlined,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          selectedIcon: Icon(
            Icons.folder,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          label: 'Vault',
        ),
      if (showAllTabs)
        NavigationDestination(
          icon: Icon(
            Icons.psychology_outlined,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          selectedIcon: Icon(
            Icons.psychology,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          label: 'Brain',
        ),
    ];

    // Clamp index to valid range when tabs change
    final safeIndex = currentIndex.clamp(0, destinations.length - 1);

    // Map visual index to actual tab for IndexedStack
    // In full mode: [Chat, Daily, Vault] -> indices 0, 1, 2
    // In daily-only mode: [Daily] -> visual index 0 maps to actual index 1
    final actualIndex = showAllTabs ? safeIndex : 1;

    // Only show navigation bar if there are multiple tabs
    final showNavBar = destinations.length > 1;

    return Scaffold(
      body: Column(
        children: [
          // Model download progress banner (only shows during download on Android)
          const ModelDownloadBanner(),
          // Main content - always create all navigators to avoid GlobalKey issues
          Expanded(
            child: IndexedStack(
              index: actualIndex,
              children: [
                // Chat tab (index 0) - hidden when not in full mode
                Navigator(
                  key: _chatNavigatorKey,
                  onGenerateRoute: (settings) {
                    return MaterialPageRoute(
                      builder: (context) => const ChatShell(),
                      settings: settings,
                    );
                  },
                ),
                // Daily tab (index 1) - always visible
                Navigator(
                  key: _dailyNavigatorKey,
                  onGenerateRoute: (settings) {
                    return MaterialPageRoute(
                      builder: (context) => const HomeScreen(),
                      settings: settings,
                    );
                  },
                ),
                // Vault tab (index 2) - hidden when not in full mode
                Navigator(
                  key: _vaultNavigatorKey,
                  onGenerateRoute: (settings) {
                    return MaterialPageRoute(
                      builder: (context) => const VaultBrowserScreen(),
                      settings: settings,
                    );
                  },
                ),
                // Brain tab (index 3) - hidden when not in full mode
                Navigator(
                  key: _brainNavigatorKey,
                  onGenerateRoute: (settings) {
                    return MaterialPageRoute(
                      builder: (context) => const BrainScreen(),
                      settings: settings,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: showNavBar
          ? NavigationBar(
              selectedIndex: safeIndex,
              onDestinationSelected: (index) {
                // Map visual index back to actual tab index
                final newActualIndex = showAllTabs ? index : 1;
                ref.read(currentTabIndexProvider.notifier).state = newActualIndex;
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
