import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/features/chat/providers/chat_providers.dart';
import 'package:parachute/features/chat/services/chat_service.dart';

/// Provider for fetching API keys from the server
final apiKeysProvider = FutureProvider<ApiKeysResponse?>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getApiKeys();
  } catch (e) {
    debugPrint('[ApiKeySection] Error fetching keys: $e');
    return null;
  }
});

/// Settings section for API key management
///
/// For localhost users (server owners):
/// - Generate new API keys for other devices
/// - View and revoke existing keys
///
/// For remote users:
/// - Enter an API key to authenticate
class ApiKeySection extends ConsumerStatefulWidget {
  const ApiKeySection({super.key});

  @override
  ConsumerState<ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends ConsumerState<ApiKeySection> {
  final _apiKeyController = TextEditingController();
  final _labelController = TextEditingController();
  bool _isGenerating = false;
  String? _newlyCreatedKey;

  @override
  void dispose() {
    _apiKeyController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _saveApiKey() async {
    final key = _apiKeyController.text.trim();
    await ref.read(apiKeyProvider.notifier).setApiKey(key.isEmpty ? null : key);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(key.isEmpty ? 'API key cleared' : 'API key saved'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Future<void> _generateKey() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Enter a device name first'),
          backgroundColor: BrandColors.warning,
        ),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      final service = ref.read(chatServiceProvider);
      final result = await service.createApiKey(label);

      setState(() {
        _newlyCreatedKey = result.key;
        _labelController.clear();
      });

      // Refresh the keys list
      ref.invalidate(apiKeysProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('API key created - copy it now!'),
            backgroundColor: BrandColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create key: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  Future<void> _deleteKey(String keyId, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke API Key?'),
        content: Text('This will immediately revoke access for "$label". '
            'The device will need a new key to reconnect.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final service = ref.read(chatServiceProvider);
      await service.deleteApiKey(keyId);
      ref.invalidate(apiKeysProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Key for "$label" revoked'),
            backgroundColor: BrandColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to revoke key: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  void _copyKey(String key) {
    Clipboard.setData(ClipboardData(text: key));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('API key copied to clipboard'),
        backgroundColor: BrandColors.success,
      ),
    );
  }

  void _dismissNewKey() {
    setState(() => _newlyCreatedKey = null);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final apiKeysAsync = ref.watch(apiKeysProvider);
    final currentKeyAsync = ref.watch(apiKeyProvider);
    final currentKey = currentKeyAsync.valueOrNull;

    // Initialize the text field with the current key
    if (currentKey != null && _apiKeyController.text.isEmpty) {
      _apiKeyController.text = currentKey;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.key,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'API Keys',
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
          'API keys allow other devices to connect to your Parachute server securely.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Show newly created key banner if present
        if (_newlyCreatedKey != null) ...[
          _NewKeyBanner(
            apiKey: _newlyCreatedKey!,
            onCopy: () => _copyKey(_newlyCreatedKey!),
            onDismiss: _dismissNewKey,
            isDark: isDark,
          ),
          SizedBox(height: Spacing.lg),
        ],

        // Current API Key input (for remote devices)
        Text(
          'Your API Key',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'If connecting to a remote server, enter the API key here.',
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.sm),
        TextField(
          controller: _apiKeyController,
          decoration: InputDecoration(
            hintText: 'para_...',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.vpn_key),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _apiKeyController.clear();
                _saveApiKey();
              },
            ),
          ),
          obscureText: true,
          onSubmitted: (_) => _saveApiKey(),
        ),
        SizedBox(height: Spacing.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _saveApiKey,
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save API Key'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
        ),

        SizedBox(height: Spacing.xl),

        // Server Key Management (only visible if we can reach the server)
        apiKeysAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ServerOfflineMessage(isDark: isDark),
          data: (data) {
            if (data == null) {
              return _ServerOfflineMessage(isDark: isDark);
            }
            return _ServerKeyManagement(
              keys: data.keys,
              authMode: data.authMode,
              labelController: _labelController,
              isGenerating: _isGenerating,
              onGenerate: _generateKey,
              onDelete: _deleteKey,
              isDark: isDark,
            );
          },
        ),
      ],
    );
  }
}

/// Banner showing a newly created API key
class _NewKeyBanner extends StatelessWidget {
  final String apiKey;
  final VoidCallback onCopy;
  final VoidCallback onDismiss;
  final bool isDark;

  const _NewKeyBanner({
    required this.apiKey,
    required this.onCopy,
    required this.onDismiss,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: BrandColors.success.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: BrandColors.success),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: BrandColors.success, size: 20),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'New API Key Created',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Copy this key now - it won\'t be shown again!',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: BrandColors.warning,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: Spacing.sm),
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightSurface : BrandColors.cream,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    apiKey,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: onCopy,
                  tooltip: 'Copy to clipboard',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Message shown when server is not reachable
class _ServerOfflineMessage extends StatelessWidget {
  final bool isDark;

  const _ServerOfflineMessage({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Connect to a server to manage API keys',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Server key management section (for localhost users)
class _ServerKeyManagement extends StatelessWidget {
  final List<ApiKeyInfo> keys;
  final String authMode;
  final TextEditingController labelController;
  final bool isGenerating;
  final VoidCallback onGenerate;
  final void Function(String keyId, String label) onDelete;
  final bool isDark;

  const _ServerKeyManagement({
    required this.keys,
    required this.authMode,
    required this.labelController,
    required this.isGenerating,
    required this.onGenerate,
    required this.onDelete,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Divider
        Divider(
          color: isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.driftwood.withValues(alpha: 0.3),
        ),
        SizedBox(height: Spacing.lg),

        // Section header
        Text(
          'Server Key Management',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.xs),
        Text(
          'Auth mode: $authMode',
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            fontFamily: 'monospace',
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.md),

        // Generate new key
        Text(
          'Generate Key for Device',
          style: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: labelController,
                decoration: const InputDecoration(
                  hintText: 'Device name (e.g., iPhone)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(width: Spacing.sm),
            FilledButton(
              onPressed: isGenerating ? null : onGenerate,
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              child: isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Generate'),
            ),
          ],
        ),

        // Existing keys
        if (keys.isNotEmpty) ...[
          SizedBox(height: Spacing.lg),
          Text(
            'Active Keys',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          SizedBox(height: Spacing.sm),
          ...keys.map((key) => _KeyRow(
            keyInfo: key,
            onDelete: () => onDelete(key.id, key.label),
            isDark: isDark,
          )),
        ] else ...[
          SizedBox(height: Spacing.md),
          Text(
            'No API keys configured yet.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontStyle: FontStyle.italic,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ],
      ],
    );
  }
}

/// Row showing an API key
class _KeyRow extends StatelessWidget {
  final ApiKeyInfo keyInfo;
  final VoidCallback onDelete;
  final bool isDark;

  const _KeyRow({
    required this.keyInfo,
    required this.onDelete,
    required this.isDark,
  });

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Spacing.sm),
      padding: EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
              : BrandColors.driftwood.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.smartphone,
            size: 18,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  keyInfo.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                Text(
                  keyInfo.lastUsedAt != null
                      ? 'Last used: ${_formatDate(keyInfo.lastUsedAt!)}'
                      : 'Created: ${_formatDate(keyInfo.createdAt)}',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
          Text(
            keyInfo.id,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: BrandColors.error,
            ),
            onPressed: onDelete,
            tooltip: 'Revoke key',
          ),
        ],
      ),
    );
  }
}
