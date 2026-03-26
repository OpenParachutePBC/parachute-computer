import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart';

/// Settings section for Claude authentication.
///
/// Shows token status and provides a paste flow for setting the
/// Claude OAuth token (from `claude setup-token`).
class ClaudeAuthSection extends ConsumerStatefulWidget {
  const ClaudeAuthSection({super.key});

  @override
  ConsumerState<ClaudeAuthSection> createState() => _ClaudeAuthSectionState();
}

class _ClaudeAuthSectionState extends ConsumerState<ClaudeAuthSection> {
  bool _isLoading = true;
  bool _isConfigured = false;
  String? _tokenPrefix;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _loadTokenStatus();
  }

  Future<void> _loadTokenStatus() async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);
      final headers = {
        if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

      final response = await http.get(
        Uri.parse('$serverUrl/api/settings/token'),
        headers: headers,
      ).timeout(const Duration(seconds: 5));

      if (mounted && response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _isLoading = false;
          _isConfigured = data['configured'] as bool? ?? false;
          _tokenPrefix = data['prefix'] as String?;
        });
      } else if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ClaudeAuth] Error loading token status: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showTokenDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _TokenDialog(controller: controller),
    );
    controller.dispose();

    if (result != null && result.isNotEmpty) {
      await _saveToken(result);
    }
  }

  Future<void> _saveToken(String token) async {
    setState(() {
      _message = null;
      _isError = false;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.put(
        Uri.parse('$serverUrl/api/settings/token'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({'token': token}),
      ).timeout(const Duration(seconds: 5));

      if (mounted) {
        if (response.statusCode == 200) {
          setState(() {
            _message = 'Token saved and activated.';
            _isError = false;
          });
          await _loadTokenStatus();
        } else {
          final detail = _parseErrorDetail(response);
          setState(() {
            _message = detail;
            _isError = true;
          });
        }
      }
    } catch (e) {
      debugPrint('[ClaudeAuth] Error saving token: $e');
      if (mounted) {
        setState(() {
          _message = 'Failed to save token: $e';
          _isError = true;
        });
      }
    }
  }

  String _parseErrorDetail(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['detail'] as String? ?? 'Failed to save token (${response.statusCode})';
    } catch (_) {
      return 'Failed to save token (${response.statusCode})';
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

        // Token status
        if (_isLoading)
          Text(
            'Checking token status...',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          )
        else
          _buildTokenStatus(isDark),

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

        // Update token button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _showTokenDialog,
            icon: Icon(
              _isConfigured ? Icons.refresh : Icons.vpn_key,
              size: 18,
            ),
            label: Text(_isConfigured ? 'Update Token' : 'Set Token'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
          ),
        ),

        SizedBox(height: Spacing.sm),
        Text(
          'Run `claude setup-token` in your terminal to get a token, then paste it here.',
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
      ],
    );
  }

  Widget _buildTokenStatus(bool isDark) {
    final statusColor = _isConfigured ? BrandColors.success : BrandColors.warning;
    final statusIcon = _isConfigured ? Icons.check_circle : Icons.warning_amber;
    final statusText = _isConfigured
        ? 'Token configured ($_tokenPrefix)'
        : 'Token not configured';

    return Row(
      children: [
        Icon(statusIcon, size: 16, color: statusColor),
        SizedBox(width: Spacing.xs),
        Flexible(
          child: Text(
            statusText,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: statusColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Dialog for pasting a Claude OAuth token.
class _TokenDialog extends StatelessWidget {
  final TextEditingController controller;

  const _TokenDialog({required this.controller});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      title: const Text('Set Claude Token'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Run this in your terminal:',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            Container(
              padding: EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.charcoal.withValues(alpha: 0.5)
                    : BrandColors.softWhite,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(
                'claude setup-token',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.forest,
                ),
              ),
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'Then paste the token here:',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Paste token...',
                border: OutlineInputBorder(),
              ),
              maxLines: 1,
              autofocus: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final token = controller.text.trim();
            Navigator.of(context).pop(token);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
