import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/server_providers.dart';

/// Settings section for Claude authentication (desktop only)
///
/// Shows a simple button to run `claude login` for authentication.
/// We don't try to detect auth status since Claude stores credentials
/// in ways that aren't easily accessible.
class ClaudeAuthSection extends ConsumerStatefulWidget {
  const ClaudeAuthSection({super.key});

  @override
  ConsumerState<ClaudeAuthSection> createState() => _ClaudeAuthSectionState();
}

class _ClaudeAuthSectionState extends ConsumerState<ClaudeAuthSection> {
  bool _isAuthenticating = false;
  String? _message;
  bool _isError = false;

  Future<void> _runClaudeLogin() async {
    setState(() {
      _isAuthenticating = true;
      _message = null;
      _isError = false;
    });

    try {
      // Find claude binary
      final whichResult = await Process.run('which', ['claude']);
      final claudePath = whichResult.stdout.toString().trim();

      if (claudePath.isEmpty) {
        setState(() {
          _isAuthenticating = false;
          _message = 'Claude CLI not found. Install it first.';
          _isError = true;
        });
        return;
      }

      debugPrint('[ClaudeAuth] Running: $claudePath login');

      // Run claude login - this opens a browser for OAuth
      final process = await Process.start(
        claudePath,
        ['login'],
        mode: ProcessStartMode.inheritStdio,
      );

      final exitCode = await process.exitCode;
      debugPrint('[ClaudeAuth] login exited with code: $exitCode');

      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          if (exitCode == 0) {
            _message = 'Authentication complete!';
            _isError = false;
          } else {
            _message = 'Authentication may not have completed. Try again if needed.';
            _isError = false; // Not really an error, user might have cancelled
          }
        });
      }
    } catch (e) {
      debugPrint('[ClaudeAuth] Error: $e');
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          _message = 'Error: $e';
          _isError = true;
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
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Parachute uses Claude for AI features. Run claude login to authenticate.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Message display
        if (_message != null) ...[
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (_isError ? BrandColors.error : BrandColors.success)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: (_isError ? BrandColors.error : BrandColors.success)
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isError ? Icons.error_outline : Icons.check_circle,
                  size: 20,
                  color: _isError ? BrandColors.error : BrandColors.success,
                ),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    _message!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.lg),
        ],

        // Login button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isAuthenticating ? null : _runClaudeLogin,
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
            label: Text(_isAuthenticating ? 'Opening browser...' : 'Run claude login'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
          ),
        ),

        SizedBox(height: Spacing.sm),
        Text(
          'This will open a browser window to sign in with your Anthropic account.',
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
      ],
    );
  }
}
