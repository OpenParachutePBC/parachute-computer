import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import 'package:parachute/features/settings/widgets/computer_setup_wizard.dart';
import '../widgets/claude_auth_step.dart';
import '../widgets/server_connection_step.dart';

// Import flavor detection
export 'package:parachute/core/providers/app_state_provider.dart' show isDailyOnlyFlavor;

/// Adaptive onboarding flow for first-time users
///
/// Flow varies by flavor and platform:
///
/// **Parachute Daily (daily flavor):**
/// 1. Welcome + Choose vault folder
/// 2. Ready to go (no server needed!)
///
/// **Parachute Full - Computer (bundled server):**
/// 1. Welcome + Choose vault folder
/// 2. Claude authentication (via `claude setup-token`)
/// 3. Ready to go
///
/// **Parachute Full - Mobile/Remote:**
/// 1. Welcome + Choose vault folder
/// 2. Server URL + API key
/// 3. Ready to go
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> with WidgetsBindingObserver {
  int _currentStep = 0;
  String? _vaultPath;
  final _serverUrlController = TextEditingController();
  bool _isSettingUpFolder = false;
  bool _needsManageStoragePermission = false;

  /// Whether this is a bundled Parachute Computer (has embedded server)
  /// Detected on first build
  bool? _isBundledApp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _checkAndroidPermissions();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serverUrlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Recheck permissions when returning from settings
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      _checkAndroidPermissions();
    }
  }

  Future<void> _checkAndroidPermissions() async {
    if (!Platform.isAndroid) return;

    // On Android 11+ (SDK 30+), we need MANAGE_EXTERNAL_STORAGE for full file access
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 30) {
      final status = await Permission.manageExternalStorage.status;
      if (mounted) {
        setState(() {
          _needsManageStoragePermission = !status.isGranted;
        });
      }
    }
  }

  Future<void> _requestAndroidPermission() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;

    if (androidInfo.version.sdkInt >= 30) {
      // Android 11+ - request() opens the "All files access" page directly for this app
      // This shows a simple toggle switch, much better UX than openAppSettings()
      await Permission.manageExternalStorage.request();
      // Recheck after returning from settings
      await _checkAndroidPermissions();
    } else {
      // Android 10 and below can use regular storage permission
      final status = await Permission.storage.request();
      if (status.isGranted && mounted) {
        setState(() {
          _needsManageStoragePermission = false;
        });
      }
    }
  }

  Future<void> _setupVaultFolder() async {
    setState(() => _isSettingUpFolder = true);

    try {
      // On Android 11+, check if we need to request permission first
      if (Platform.isAndroid && _needsManageStoragePermission) {
        await _requestAndroidPermission();
        if (_needsManageStoragePermission) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Please grant "All files access" permission, or use the default location.'),
                backgroundColor: BrandColors.warning,
              ),
            );
          }
          setState(() => _isSettingUpFolder = false);
          return;
        }
      }

      final service = ref.read(dailyFileSystemServiceProvider);

      // Pick folder or use default
      String? selectedPath;

      final useCustom = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose Parachute Folder'),
          content: const Text(
            'Your Parachute vault will be stored locally in this folder.\n\n'
            'Would you like to use the default location or choose a custom folder?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Use Default'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Choose Folder'),
            ),
          ],
        ),
      );

      if (useCustom == true) {
        selectedPath = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose Parachute Folder',
        );
      }

      // Initialize the folder (uses default if selectedPath is null)
      if (selectedPath != null) {
        debugPrint('[Onboarding] Setting custom vault path: $selectedPath');
        await service.setVaultPath(selectedPath, migrateFiles: false);
      } else {
        debugPrint('[Onboarding] Using default vault path');
        await service.initialize();
      }

      // Mark as configured so onboarding knows it's done
      await service.markAsConfigured();

      final displayPath = await service.getVaultPathDisplay();
      debugPrint('[Onboarding] Vault path set to: $displayPath');

      // Invalidate providers so they use the new path
      ref.invalidate(journalServiceFutureProvider);
      ref.invalidate(dailyRootPathProvider);

      setState(() {
        _vaultPath = displayPath;
        _isSettingUpFolder = false;
      });

      _nextStep();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error setting up folder: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
      setState(() => _isSettingUpFolder = false);
    }
  }

  Future<void> _useDefaultFolder() async {
    setState(() => _isSettingUpFolder = true);

    try {
      final service = ref.read(dailyFileSystemServiceProvider);
      await service.initialize();
      await service.markAsConfigured();

      final displayPath = await service.getVaultPathDisplay();

      // Invalidate providers so they use the new path
      ref.invalidate(journalServiceFutureProvider);
      ref.invalidate(dailyRootPathProvider);

      setState(() {
        _vaultPath = displayPath;
        _isSettingUpFolder = false;
      });

      _nextStep();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error setting up folder: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
      setState(() => _isSettingUpFolder = false);
    }
  }

  /// Whether we've completed the computer setup (for computer flavor)
  bool _computerSetupComplete = false;

  /// Total number of steps depends on flavor
  /// - Daily flavor: 2 steps (welcome, ready)
  /// - Client flavor: 3 steps (welcome, server connection, ready)
  /// - Computer flavor: 3 steps (welcome, computer setup wizard, ready)
  int get _totalSteps => isDailyOnlyFlavor ? 2 : 3;

  void _nextStep() {
    if (_currentStep < _totalSteps - 1) {
      setState(() => _currentStep++);
    } else {
      _completeOnboarding();
    }
  }

  Future<void> _completeOnboarding() async {
    // Mark onboarding as complete
    await ref.read(onboardingCompleteProvider.notifier).markComplete();

    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Spacing.xl),
          child: Column(
            children: [
              // Progress indicator
              Row(
                children: List.generate(_totalSteps, (index) {
                  final isActive = index <= _currentStep;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.symmetric(horizontal: Spacing.xs),
                      decoration: BoxDecoration(
                        color: isActive
                            ? BrandColors.turquoise
                            : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
              SizedBox(height: Spacing.xxl),

              // Step content
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _buildStep(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(bool isDark) {
    // Detect bundled mode on first build (lazy initialization)
    _isBundledApp ??= ref.read(isBundledAppProvider);

    debugPrint('[Onboarding] _buildStep: step=$_currentStep, flavor=$appFlavor, isDailyOnly=$isDailyOnlyFlavor, isBundled=$_isBundledApp, isComputer=$isComputerFlavor, totalSteps=$_totalSteps');

    switch (_currentStep) {
      case 0:
        return _buildWelcomeStep(isDark);
      case 1:
        // Daily flavor: Skip server setup entirely, go straight to ready
        if (isDailyOnlyFlavor) {
          debugPrint('[Onboarding] Daily flavor detected, showing ready step');
          return _buildReadyStep(isDark);
        }
        // Computer flavor: Show setup wizard (mode selection + setup steps)
        if (isComputerFlavor || _isBundledApp == true) {
          debugPrint('[Onboarding] Computer flavor detected, showing setup wizard');
          return _buildComputerSetupStep(isDark);
        }
        // Client flavor: Server URL + API key for remote connection
        return ServerConnectionStep(
          onNext: _nextStep,
          onSkip: _nextStep,
        );
      case 2:
        return _buildReadyStep(isDark);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildComputerSetupStep(bool isDark) {
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.md),
        child: ComputerSetupWizard(
          onComplete: () {
            setState(() {
              _computerSetupComplete = true;
            });
            _nextStep();
          },
        ),
      ),
    );
  }

  Widget _buildWelcomeStep(bool isDark) {
    return SingleChildScrollView(
      child: Column(
        key: const ValueKey('welcome'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.wb_sunny,
            size: 80,
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
          SizedBox(height: Spacing.xl),
          Text(
            isDailyOnlyFlavor ? 'Welcome to Parachute Daily' : 'Welcome to Parachute',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Spacing.md),
          Text(
            isDailyOnlyFlavor
                ? 'Voice journaling, locally stored.'
                : 'Your extended mind, locally stored.',
            style: TextStyle(
              fontSize: TypographyTokens.bodyLarge,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Spacing.xxl),

          // Android permission banner
          if (Platform.isAndroid && _needsManageStoragePermission) ...[
            Container(
              padding: const EdgeInsets.all(16),
              margin: EdgeInsets.symmetric(horizontal: Spacing.sm),
              decoration: BoxDecoration(
                color: BrandColors.warningLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrandColors.warning),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.folder_off, color: BrandColors.warning, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Files Access Required',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: BrandColors.charcoal,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'To choose a custom folder, grant "All files access" in Settings. Or use the default location below.',
                    style: TextStyle(
                      fontSize: 13,
                      color: BrandColors.driftwood,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _requestAndroidPermission,
                      icon: const Icon(Icons.settings, size: 18),
                      label: const Text('Open Settings'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BrandColors.warning,
                        side: BorderSide(color: BrandColors.warning),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: Spacing.lg),
          ],

          Text(
            'First, let\'s set up where your data will be stored.',
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Spacing.xl),

          if (_isSettingUpFolder)
            const CircularProgressIndicator()
          else ...[
            // Choose folder button
            FilledButton.icon(
              onPressed: _setupVaultFolder,
              icon: const Icon(Icons.folder),
              label: const Text('Choose Folder'),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.xl,
                  vertical: Spacing.md,
                ),
              ),
            ),
            SizedBox(height: Spacing.md),

            // Use default button
            TextButton(
              onPressed: _useDefaultFolder,
              style: TextButton.styleFrom(
                foregroundColor: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.xl,
                  vertical: Spacing.md,
                ),
              ),
              child: Text(
                Platform.isMacOS || Platform.isLinux
                    ? 'Use default (~/Parachute)'
                    : 'Use default location',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReadyStep(bool isDark) {
    // Determine what to show based on flavor
    final isComputer = isComputerFlavor || _isBundledApp == true;

    return Column(
      key: const ValueKey('ready'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.check_circle,
          size: 80,
          color: BrandColors.success,
        ),
        SizedBox(height: Spacing.xl),
        Text(
          'You\'re All Set!',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: Spacing.md),

        // Summary
        Container(
          margin: EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.lg),
          padding: EdgeInsets.all(Spacing.lg),
          decoration: BoxDecoration(
            color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.folder, color: BrandColors.forest, size: 20),
                  SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      _vaultPath ?? '~/Parachute',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ),
                ],
              ),
              // Show server info for computer flavor
              if (isComputer) ...[
                SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Icon(Icons.computer, color: BrandColors.turquoise, size: 20),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'Server running at localhost:3333',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
              ]
              // Show remote server URL for client flavor
              else if (_serverUrlController.text.isNotEmpty) ...[
                SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Icon(Icons.cloud, color: BrandColors.turquoise, size: 20),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        _serverUrlController.text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        Text(
          'Start capturing thoughts, ideas, and reflections.',
          style: TextStyle(
            fontSize: TypographyTokens.bodyMedium,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: Spacing.xxl),
        FilledButton.icon(
          onPressed: _completeOnboarding,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Get Started'),
          style: FilledButton.styleFrom(
            backgroundColor: BrandColors.turquoise,
            padding: EdgeInsets.symmetric(
              horizontal: Spacing.xxl,
              vertical: Spacing.md,
            ),
          ),
        ),
      ],
    );
  }
}
