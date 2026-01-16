import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/features/onboarding/widgets/claude_auth_step.dart';

/// Settings section for managing Claude authentication (desktop only)
///
/// Shows:
/// - Current authentication status
/// - Re-authenticate button
/// - Last authentication info
class ClaudeAuthSection extends ConsumerStatefulWidget {
  const ClaudeAuthSection({super.key});

  @override
  ConsumerState<ClaudeAuthSection> createState() => _ClaudeAuthSectionState();
}

class _ClaudeAuthSectionState extends ConsumerState<ClaudeAuthSection> {
  bool _isChecking = false;
  bool _isAuthenticating = false;
  bool? _isAuthenticated;
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

    try {
      final isAuth = await checkClaudeAuth();
      if (mounted) {
        setState(() {
          _isAuthenticated = isAuth;
          _isChecking = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isChecking = false;
          _errorMessage = 'Error checking authentication: $e';
        });
      }
    }
  }

  Future<void> _reauthenticate() async {
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    try {
      final success = await runClaudeSetupToken();

      if (mounted) {
        if (success) {
          // Verify the new authentication
          await _checkAuthStatus();

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Claude authentication successful'),
              backgroundColor: BrandColors.success,
            ),
          );
        } else {
          setState(() {
            _isAuthenticating = false;
            _errorMessage = 'Authentication was not completed';
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
    final isBundled = ref.watch(isBundledAppProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Only show this section for bundled apps on desktop
    if (!isBundled) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.account_circle,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Claude Authentication',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const Spacer(),
            _AuthStatusBadge(
              isChecking: _isChecking,
              isAuthenticated: _isAuthenticated,
              isDark: isDark,
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Parachute Computer uses your Claude account for AI features.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),

        // Authentication status display
        if (_isAuthenticated == true) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.success.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 20, color: BrandColors.success),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Claude is authenticated and ready to use',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else if (_isAuthenticated == false) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.warning.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 20, color: BrandColors.warning),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Claude is not authenticated. Sign in to use AI features.',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Error message
        if (_errorMessage != null) ...[
          SizedBox(height: Spacing.md),
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 20, color: BrandColors.error),
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
        ],

        SizedBox(height: Spacing.lg),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isChecking || _isAuthenticating ? null : _checkAuthStatus,
                icon: _isChecking
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                        ),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_isChecking ? 'Checking...' : 'Check Status'),
              ),
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: _isChecking || _isAuthenticating ? null : _reauthenticate,
                icon: _isAuthenticating
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            BrandColors.softWhite,
                          ),
                        ),
                      )
                    : const Icon(Icons.login, size: 18),
                label: Text(_isAuthenticating
                    ? 'Signing in...'
                    : (_isAuthenticated == true ? 'Re-authenticate' : 'Sign In')),
                style: FilledButton.styleFrom(
                  backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Status badge showing authentication state
class _AuthStatusBadge extends StatelessWidget {
  final bool isChecking;
  final bool? isAuthenticated;
  final bool isDark;

  const _AuthStatusBadge({
    required this.isChecking,
    required this.isAuthenticated,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = isChecking
        ? (Icons.sync, 'Checking', BrandColors.turquoise)
        : isAuthenticated == true
            ? (Icons.check_circle, 'Signed In', BrandColors.success)
            : isAuthenticated == false
                ? (Icons.warning_amber, 'Not Signed In', BrandColors.warning)
                : (Icons.help_outline, 'Unknown', BrandColors.driftwood);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          isChecking
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              : Icon(icon, size: 14, color: color),
          SizedBox(width: Spacing.xs),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
