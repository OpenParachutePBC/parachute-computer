import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/services/backend_health_service.dart';

/// Onboarding step for connecting to a remote Parachute server
///
/// This step is shown for mobile devices or remote clients that need to:
/// 1. Enter a server URL
/// 2. Optionally provide an API key for authentication
class ServerConnectionStep extends ConsumerStatefulWidget {
  final VoidCallback onNext;
  final VoidCallback? onSkip;

  const ServerConnectionStep({
    super.key,
    required this.onNext,
    this.onSkip,
  });

  @override
  ConsumerState<ServerConnectionStep> createState() => _ServerConnectionStepState();
}

class _ServerConnectionStepState extends ConsumerState<ServerConnectionStep> {
  final _serverUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  bool _isConnecting = false;
  bool _showApiKey = false;
  String? _errorMessage;
  bool _connectionSuccess = false;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _testAndSaveConnection() async {
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) {
      setState(() => _errorMessage = 'Please enter a server URL');
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
      _connectionSuccess = false;
    });

    // Test the connection
    final healthService = BackendHealthService(baseUrl: url);
    try {
      final status = await healthService.checkHealth();

      if (mounted) {
        if (status.isHealthy) {
          // Save the URL
          final featureFlags = ref.read(featureFlagsServiceProvider);
          await featureFlags.setAiServerUrl(url);
          featureFlags.clearCache();
          ref.invalidate(aiServerUrlProvider);

          // Save API key if provided
          final apiKey = _apiKeyController.text.trim();
          if (apiKey.isNotEmpty) {
            await ref.read(apiKeyProvider.notifier).setApiKey(apiKey);
          }

          // Also update serverUrlProvider for app mode detection
          await ref.read(serverUrlProvider.notifier).setServerUrl(url);

          setState(() {
            _isConnecting = false;
            _connectionSuccess = true;
          });

          // Auto-advance after showing success
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) {
              widget.onNext();
            }
          });
        } else {
          setState(() {
            _isConnecting = false;
            _errorMessage = '${status.message}: ${status.helpText}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'Connection failed: $e';
        });
      }
    } finally {
      healthService.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      child: Column(
        key: const ValueKey('server-connection'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _connectionSuccess ? Icons.check_circle : Icons.cloud_outlined,
            size: 80,
            color: _connectionSuccess
                ? BrandColors.success
                : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
          ),
          SizedBox(height: Spacing.xl),
          Text(
            _connectionSuccess ? 'Connected!' : 'Connect to Server',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Spacing.md),
          Text(
            _connectionSuccess
                ? 'Your device is connected to the Parachute server.'
                : 'Connect to a Parachute Base server for AI Chat features.',
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Spacing.xxl),

          if (_connectionSuccess)
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
                    _serverUrlController.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Column(
                children: [
                  // Error message
                  if (_errorMessage != null) ...[
                    Container(
                      padding: EdgeInsets.all(Spacing.md),
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

                  // Server URL field
                  TextField(
                    controller: _serverUrlController,
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.100:3333',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.link),
                    ),
                    keyboardType: TextInputType.url,
                    enabled: !_isConnecting,
                    onSubmitted: (_) => _testAndSaveConnection(),
                  ),
                  SizedBox(height: Spacing.md),

                  // API Key toggle
                  Row(
                    children: [
                      Switch(
                        value: _showApiKey,
                        onChanged: _isConnecting
                            ? null
                            : (value) => setState(() => _showApiKey = value),
                        activeTrackColor: BrandColors.turquoise,
                      ),
                      SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          'I have an API key',
                          style: TextStyle(
                            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // API Key field
                  if (_showApiKey) ...[
                    SizedBox(height: Spacing.md),
                    TextField(
                      controller: _apiKeyController,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        hintText: 'Enter your API key',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.key),
                      ),
                      obscureText: true,
                      enabled: !_isConnecting,
                    ),
                    SizedBox(height: Spacing.sm),
                    Text(
                      'Get an API key from Settings on your Parachute Computer.',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                    ),
                  ],

                  SizedBox(height: Spacing.xl),

                  // Connect button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isConnecting ? null : _testAndSaveConnection,
                      icon: _isConnecting
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
                          : const Icon(Icons.wifi_tethering),
                      label: Text(_isConnecting ? 'Connecting...' : 'Connect'),
                      style: FilledButton.styleFrom(
                        backgroundColor: BrandColors.turquoise,
                        padding: EdgeInsets.symmetric(vertical: Spacing.md),
                      ),
                    ),
                  ),

                  if (widget.onSkip != null) ...[
                    SizedBox(height: Spacing.md),
                    TextButton(
                      onPressed: _isConnecting ? null : widget.onSkip,
                      style: TextButton.styleFrom(
                        foregroundColor: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      child: const Text('Skip - Daily only mode'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
