import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';

export 'package:parachute/core/providers/app_state_provider.dart' show isDailyOnlyFlavor;

/// Onboarding flow for Parachute Daily v2.
/// Simple: Welcome → Ready to go.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _currentStep = 0;

  void _next() {
    if (_currentStep == 0) {
      // Mark onboarding complete and go
      _completeOnboarding();
    }
  }

  Future<void> _completeOnboarding() async {
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
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),

              // Logo / title
              Icon(
                Icons.today,
                size: 80,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(height: Spacing.xl),
              Text(
                'Parachute Daily',
                style: TextStyle(
                  fontSize: TypographyTokens.headlineLarge,
                  fontWeight: FontWeight.bold,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              SizedBox(height: Spacing.md),
              Text(
                'Your personal graph.\nJournal in, AI plugs in.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),

              const Spacer(),

              // Get started button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  style: FilledButton.styleFrom(
                    backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                    padding: EdgeInsets.symmetric(vertical: Spacing.md),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                  ),
                  child: const Text(
                    'Get Started',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

              SizedBox(height: Spacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}
