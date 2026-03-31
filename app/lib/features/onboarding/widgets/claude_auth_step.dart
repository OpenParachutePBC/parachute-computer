import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Enum for Claude authentication status
enum ClaudeAuthStatus {
  unknown,
  checking,
  authenticated,
  notAuthenticated,
  error,
}

/// Provider for checking Claude authentication status
final claudeAuthStatusProvider = StateProvider<ClaudeAuthStatus>((ref) {
  return ClaudeAuthStatus.unknown;
});

/// Check if Claude CLI is authenticated by running `claude --version`
/// and checking if credentials exist
Future<bool> checkClaudeAuth() async {
  try {
    // Check if ~/.claude/credentials.json exists
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return false;

    final credentialsFile = File('$home/.claude/credentials.json');
    if (await credentialsFile.exists()) {
      final content = await credentialsFile.readAsString();
      // Check if it has actual content (not empty or just {})
      return content.trim().length > 2;
    }
    return false;
  } catch (e) {
    debugPrint('[ClaudeAuth] Error checking credentials: $e');
    return false;
  }
}

/// Run `claude setup-token` to authenticate
Future<bool> runClaudeSetupToken() async {
  try {
    // Find claude binary
    final result = await Process.run('which', ['claude']);
    final claudePath = result.stdout.toString().trim();

    if (claudePath.isEmpty) {
      debugPrint('[ClaudeAuth] claude binary not found');
      return false;
    }

    debugPrint('[ClaudeAuth] Running: $claudePath setup-token');

    // Run setup-token - this opens a browser for OAuth
    final process = await Process.start(
      claudePath,
      ['setup-token'],
      mode: ProcessStartMode.inheritStdio,
    );

    final exitCode = await process.exitCode;
    debugPrint('[ClaudeAuth] setup-token exited with code: $exitCode');

    return exitCode == 0;
  } catch (e) {
    debugPrint('[ClaudeAuth] Error running setup-token: $e');
    return false;
  }
}

/// Onboarding step for Claude authentication (used in Parachute Computer)
///
/// This step:
/// 1. Checks if Claude CLI is already authenticated
/// 2. If not, prompts user to authenticate via `claude setup-token`
/// 3. Shows status and allows retry
class ClaudeAuthStep extends ConsumerStatefulWidget {
  final VoidCallback onNext;
  final VoidCallback? onSkip;

  const ClaudeAuthStep({
    super.key,
    required this.onNext,
    this.onSkip,
  });

  @override
  ConsumerState<ClaudeAuthStep> createState() => _ClaudeAuthStepState();
}

class _ClaudeAuthStepState extends ConsumerState<ClaudeAuthStep> {
  bool _isChecking = false;
  bool _isAuthenticating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    setState(() {
      _isChecking = true;
      _errorMessage = null;
    });

    ref.read(claudeAuthStatusProvider.notifier).state = ClaudeAuthStatus.checking;

    try {
      final isAuthenticated = await checkClaudeAuth();

      if (mounted) {
        ref.read(claudeAuthStatusProvider.notifier).state =
            isAuthenticated ? ClaudeAuthStatus.authenticated : ClaudeAuthStatus.notAuthenticated;

        setState(() => _isChecking = false);

        // If already authenticated, auto-advance
        if (isAuthenticated) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              widget.onNext();
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ref.read(claudeAuthStatusProvider.notifier).state = ClaudeAuthStatus.error;
        setState(() {
          _isChecking = false;
          _errorMessage = 'Error checking authentication: $e';
        });
      }
    }
  }

  Future<void> _authenticate() async {
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    try {
      final success = await runClaudeSetupToken();

      if (mounted) {
        if (success) {
          // Verify authentication was successful
          await _checkAuthStatus();
        } else {
          setState(() {
            _isAuthenticating = false;
            _errorMessage = 'Authentication was not completed. Please try again.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          _errorMessage = 'Error during authentication: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authStatus = ref.watch(claudeAuthStatusProvider);

    return Column(
      key: const ValueKey('claude-auth'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          authStatus == ClaudeAuthStatus.authenticated
              ? Icons.check_circle
              : Icons.account_circle,
          size: 80,
          color: authStatus == ClaudeAuthStatus.authenticated
              ? BrandColors.success
              : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
        ),
        SizedBox(height: Spacing.xl),
        Text(
          authStatus == ClaudeAuthStatus.authenticated
              ? 'Claude Connected!'
              : 'Connect to Claude',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: Spacing.md),
        Text(
          authStatus == ClaudeAuthStatus.authenticated
              ? 'Your Parachute Computer is ready to use Claude AI.'
              : 'Parachute Computer uses Claude for AI features. Sign in with your Anthropic account to continue.',
          style: TextStyle(
            fontSize: TypographyTokens.bodyMedium,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: Spacing.xxl),

        // Status/action area
        if (_isChecking || _isAuthenticating)
          Column(
            children: [
              const CircularProgressIndicator(),
              SizedBox(height: Spacing.md),
              Text(
                _isChecking ? 'Checking authentication...' : 'Opening browser for sign in...',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          )
        else if (authStatus == ClaudeAuthStatus.authenticated)
          Column(
            children: [
              Container(
                padding: EdgeInsets.all(Spacing.md),
                decoration: BoxDecoration(
                  color: BrandColors.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: BrandColors.success.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: BrandColors.success),
                    SizedBox(width: Spacing.sm),
                    Text(
                      'Successfully authenticated',
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Spacing.xl),
              FilledButton.icon(
                onPressed: widget.onNext,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Continue'),
                style: FilledButton.styleFrom(
                  backgroundColor: BrandColors.turquoise,
                  padding: EdgeInsets.symmetric(
                    horizontal: Spacing.xl,
                    vertical: Spacing.md,
                  ),
                ),
              ),
            ],
          )
        else
          Column(
            children: [
              if (_errorMessage != null) ...[
                Container(
                  padding: EdgeInsets.all(Spacing.md),
                  margin: EdgeInsets.symmetric(horizontal: Spacing.lg),
                  decoration: BoxDecoration(
                    color: BrandColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning, color: BrandColors.error, size: 20),
                      SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: BrandColors.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: Spacing.lg),
              ],

              // Info box
              Container(
                padding: EdgeInsets.all(Spacing.md),
                margin: EdgeInsets.symmetric(horizontal: Spacing.lg),
                decoration: BoxDecoration(
                  color: (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone)
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                        SizedBox(width: Spacing.xs),
                        Text(
                          'What happens next:',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: TypographyTokens.bodySmall,
                            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: Spacing.sm),
                    Text(
                      '1. A browser window will open\n'
                      '2. Sign in with your Anthropic account\n'
                      '3. Return here to continue',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Spacing.xl),

              FilledButton.icon(
                onPressed: _authenticate,
                icon: const Icon(Icons.login),
                label: const Text('Sign In with Claude'),
                style: FilledButton.styleFrom(
                  backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                  padding: EdgeInsets.symmetric(
                    horizontal: Spacing.xl,
                    vertical: Spacing.md,
                  ),
                ),
              ),

              if (widget.onSkip != null) ...[
                SizedBox(height: Spacing.md),
                TextButton(
                  onPressed: widget.onSkip,
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  child: const Text('Skip for now'),
                ),
              ],
            ],
          ),
      ],
    );
  }
}
