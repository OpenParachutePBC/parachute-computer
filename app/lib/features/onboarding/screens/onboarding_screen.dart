import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/server_providers.dart';
import '../widgets/server_connection_step.dart';

// Import flavor detection
export 'package:parachute/core/providers/app_state_provider.dart' show isDailyOnlyFlavor;

/// Adaptive onboarding flow for first-time users
///
/// Flow varies by flavor and platform:
///
/// **Parachute Daily (daily flavor):**
/// 1. Welcome
/// 2. Ready to go (no server needed!)
///
/// **Parachute Full - Computer (bundled server):**
/// 1. Computer setup wizard (Claude auth, server config)
/// 2. Ready to go
///
/// **Parachute Full - Mobile/Remote:**
/// 1. Welcome
/// 2. Server URL + API key
/// 3. Ready to go
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _currentStep = 0;

  /// Whether this is a bundled Parachute Computer (has embedded server).
  /// Read once in initState — isBundledAppProvider is compile-time constant.
  late bool _isBundledApp;

  @override
  void initState() {
    super.initState();
    _isBundledApp = ref.read(isBundledAppProvider);
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _continueFromWelcome() async {
    final service = ref.read(dailyFileSystemServiceProvider);
    await service.initialize();
    if (!mounted) return;
    _nextStep();
  }

  /// Total number of steps depends on flavor
  /// - Daily flavor: 2 steps (welcome, ready)
  /// - Client flavor: 3 steps (welcome, server connection, ready)
  /// - Computer flavor: 2 steps (computer setup wizard handles vault, ready)
  int get _totalSteps {
    if (isDailyOnlyFlavor) return 2;
    if (isComputerFlavor || _isBundledApp == true) return 2;
    return 3; // Client flavor
  }

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
    debugPrint('[Onboarding] _buildStep: step=$_currentStep, flavor=$appFlavor, isDailyOnly=$isDailyOnlyFlavor, isBundled=$_isBundledApp, isComputer=$isComputerFlavor, totalSteps=$_totalSteps');

    // Computer flavor has its own flow - wizard handles vault selection
    if (isComputerFlavor || _isBundledApp == true) {
      switch (_currentStep) {
        case 0:
          debugPrint('[Onboarding] Computer flavor: showing setup wizard');
          return _buildComputerSetupStep(isDark);
        case 1:
          return _buildReadyStep(isDark);
        default:
          return const SizedBox.shrink();
      }
    }

    // Daily and Client flavors start with welcome/vault selection
    switch (_currentStep) {
      case 0:
        return _buildWelcomeStep(isDark);
      case 1:
        // Daily flavor: Skip server setup entirely, go straight to ready
        if (isDailyOnlyFlavor) {
          debugPrint('[Onboarding] Daily flavor detected, showing ready step');
          return _buildReadyStep(isDark);
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
          onComplete: _nextStep,
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
          FilledButton.icon(
            onPressed: _continueFromWelcome,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Get Started'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              padding: EdgeInsets.symmetric(
                horizontal: Spacing.xl,
                vertical: Spacing.md,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadyStep(bool isDark) {
    // Determine what to show based on flavor
    final isComputer = isComputerFlavor || _isBundledApp == true;

    // For computer flavor, get vault path from provider (set by ComputerSetupWizard)
    final vaultPathAsync = ref.watch(vaultPathProvider);
    final displayVaultPath = vaultPathAsync.when(
      data: (path) => path ?? '~',
      loading: () => '~',
      error: (_, __) => '~',
    );

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
              // Show vault path for computer flavor
              if (isComputer) ...[
                Row(
                  children: [
                    Icon(Icons.folder, color: BrandColors.forest, size: 20),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        displayVaultPath,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
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
              ] else ...[
                Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: BrandColors.success, size: 20),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'Data stored locally on this device',
                        style: TextStyle(
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
