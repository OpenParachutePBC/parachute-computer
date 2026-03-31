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
import 'core/providers/app_state_provider.dart';
import 'core/providers/sync_provider.dart';
import 'core/providers/core_service_providers.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/file_system_service.dart';
import 'core/services/logging_service.dart';
import 'core/services/model_download_service.dart';
import 'core/widgets/model_download_banner.dart';
import 'features/daily/home/screens/home_screen.dart';
import 'features/daily/recorder/providers/omi_providers.dart';
import 'features/daily/journal/providers/journal_providers.dart';
import 'features/settings/screens/settings_screen.dart';
import 'features/onboarding/screens/onboarding_screen.dart';

void main() async {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  final container = ProviderContainer();

  await FileSystemService.runMigrations();
  await initializeGlobalServices(container);

  logger.info('Main', 'Starting Parachute Daily...');

  await _initializeServices();

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

  // Initialize transcription model download in background
  _initializeTranscription();
}

void _initializeTranscription() async {
  if (!Platform.isAndroid) return;
  try {
    final downloadService = ModelDownloadService();
    await downloadService.initialize();
    if (downloadService.currentState.isReady) return;
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
      title: 'Parachute Daily',
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

/// Main shell - handles onboarding then shows the daily journal
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
        return const _DailyShell();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const _DailyShell(),
    );
  }
}

/// Daily-only shell — no tabs, just the journal
class _DailyShell extends ConsumerStatefulWidget {
  const _DailyShell();

  @override
  ConsumerState<_DailyShell> createState() => _DailyShellState();
}

class _DailyShellState extends ConsumerState<_DailyShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Sync provider - ready when journal entries are created
      ref.read(syncProvider.notifier);

      // Omi services - Bluetooth for connection, Capture for recording
      if (Platform.isAndroid || Platform.isIOS) {
        ref.read(omiBluetoothServiceProvider);
        Future.delayed(const Duration(milliseconds: 100), () {
          ref.read(omiCaptureServiceProvider);
        });
      }
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

    // Handle Omi auto-reconnect on app resume
    if (state == AppLifecycleState.resumed && (Platform.isAndroid || Platform.isIOS)) {
      final bluetoothService = ref.read(omiBluetoothServiceProvider);
      if (!bluetoothService.isConnected) {
        _attemptOmiAutoReconnect();
      }
    }
  }

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
    // Listen for deep links
    ref.listen<AsyncValue<DeepLinkTarget>>(deepLinkStreamProvider, (previous, next) {
      next.whenData((target) {
        if (target.tab == 'settings') {
          Navigator.of(context).pushNamed('/settings');
        } else if (target.tab == 'daily' && target.date != null) {
          final parts = target.date!.split('-');
          if (parts.length == 3) {
            final year = int.tryParse(parts[0]);
            final month = int.tryParse(parts[1]);
            final day = int.tryParse(parts[2]);
            if (year != null && month != null && day != null) {
              ref.read(selectedJournalDateProvider.notifier).state =
                  DateTime(year, month, day);
            }
          }
        }
      });
    });

    return Scaffold(
      body: Column(
        children: [
          const ModelDownloadBanner(),
          const Expanded(child: HomeScreen()),
        ],
      ),
    );
  }
}
