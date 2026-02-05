import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show serverUrlProvider, apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/services/backend_health_service.dart';

/// Server connection settings section
class ServerSettingsSection extends ConsumerStatefulWidget {
  const ServerSettingsSection({super.key});

  @override
  ConsumerState<ServerSettingsSection> createState() => _ServerSettingsSectionState();
}

class _ServerSettingsSectionState extends ConsumerState<ServerSettingsSection> {
  final _serverUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadServerUrl();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadServerUrl() async {
    final featureFlags = ref.read(featureFlagsServiceProvider);
    final serverUrl = await featureFlags.getAiServerUrl();
    if (mounted) {
      _serverUrlController.text = serverUrl;
    }
  }

  Future<void> _saveServerUrl() async {
    final url = _serverUrlController.text.trim();
    final featureFlags = ref.read(featureFlagsServiceProvider);

    try {
      // Save using FeatureFlagsService (same key as working chat app)
      await featureFlags.setAiServerUrl(url.isEmpty ? 'http://localhost:3333' : url);
      featureFlags.clearCache();

      // Invalidate the provider so ChatService rebuilds with the new URL
      ref.invalidate(aiServerUrlProvider);

      // Also update serverUrlProvider for app mode detection (validates URL)
      await ref.read(serverUrlProvider.notifier).setServerUrl(url.isEmpty ? null : url);

      // Reinitialize sync with new server URL
      if (url.isNotEmpty) {
        final apiKey = await ref.read(apiKeyProvider.future);
        await ref.read(syncProvider.notifier).reinitialize(url, apiKey: apiKey);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(url.isEmpty
                ? 'Server URL cleared - Daily only mode'
                : 'Server URL saved - Chat & Vault enabled'),
            backgroundColor: BrandColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid URL: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _testServerConnection() async {
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Enter a server URL first'),
          backgroundColor: BrandColors.warning,
        ),
      );
      return;
    }

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
              ),
            ),
            SizedBox(width: Spacing.md),
            const Text('Testing connection...'),
          ],
        ),
        duration: const Duration(seconds: 10),
      ),
    );

    // Actually test the connection
    final healthService = BackendHealthService(baseUrl: url);
    try {
      final status = await healthService.checkHealth();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        if (status.isHealthy) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(status.serverVersion != null
                  ? 'Connected to Parachute Base v${status.serverVersion}'
                  : 'Connected to Parachute Base'),
              backgroundColor: BrandColors.success,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${status.message}: ${status.helpText}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      healthService.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.cloud_outlined,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Parachute Base Server',
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
          'Connect to a Parachute Base server to enable AI Chat and Vault features. '
          'Leave empty for offline Daily-only mode.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        TextField(
          controller: _serverUrlController,
          decoration: InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://localhost:3333',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.link),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _serverUrlController.clear();
                _saveServerUrl();
              },
            ),
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _saveServerUrl(),
        ),
        SizedBox(height: Spacing.lg),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testServerConnection,
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Test Connection'),
              ),
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saveServerUrl,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save'),
                style: FilledButton.styleFrom(
                  backgroundColor: BrandColors.turquoise,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
