import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';

/// Bot connectors (Telegram, Discord) status and settings section.
class BotConnectorsSection extends ConsumerStatefulWidget {
  const BotConnectorsSection({super.key});

  @override
  ConsumerState<BotConnectorsSection> createState() => _BotConnectorsSectionState();
}

class _BotConnectorsSectionState extends ConsumerState<BotConnectorsSection> {
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _config;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStatus());
  }

  Future<void> _loadStatus() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);
      final headers = {
        if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

      final statusResponse = await http.get(
        Uri.parse('$serverUrl/api/bots/status'),
        headers: headers,
      );

      final configResponse = await http.get(
        Uri.parse('$serverUrl/api/bots/config'),
        headers: headers,
      );

      if (mounted) {
        if (statusResponse.statusCode == 200) {
          setState(() {
            _status = json.decode(statusResponse.body) as Map<String, dynamic>;
          });
        }
        if (configResponse.statusCode == 200) {
          setState(() {
            _config = json.decode(configResponse.body) as Map<String, dynamic>;
          });
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load bot status: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _testConnection(String platform) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.post(
        Uri.parse('$serverUrl/api/bots/$platform/test'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        final success = response.statusCode == 200;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? '$platform connection successful'
                : '$platform test failed: ${response.statusCode}'),
            backgroundColor: success ? BrandColors.forest : BrandColors.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Test failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Bot Connectors',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.md),

        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(
            _error!,
            style: TextStyle(
              color: BrandColors.error,
              fontSize: TypographyTokens.bodySmall,
            ),
          )
        else ...[
          // Connector rows
          _buildConnectorRow('Telegram', 'telegram', Icons.telegram, isDark),
          SizedBox(height: Spacing.sm),
          _buildConnectorRow('Discord', 'discord', Icons.forum_outlined, isDark),

          // Trust levels
          if (_config != null) ...[
            SizedBox(height: Spacing.lg),
            Text(
              'Trust Levels',
              style: TextStyle(
                fontSize: TypographyTokens.labelLarge,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            SizedBox(height: Spacing.xs),
            _buildTrustLevel('DM', _config!['dm_trust_level'], isDark),
            _buildTrustLevel('Group', _config!['group_trust_level'], isDark),
          ],

          // Footer
          SizedBox(height: Spacing.md),
          Text(
            'Configure tokens in vault/.parachute/bots.yaml',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConnectorRow(String label, String platform, IconData icon, bool isDark) {
    final connectorStatus = _status?[platform] as Map<String, dynamic>?;
    final isRunning = connectorStatus?['running'] == true;
    final isConfigured = connectorStatus?['configured'] == true;
    final botName = connectorStatus?['bot_name'] as String?;

    Color statusColor;
    String statusLabel;
    if (isRunning) {
      statusColor = BrandColors.forest;
      statusLabel = 'Running';
    } else if (isConfigured) {
      statusColor = BrandColors.warning;
      statusLabel = 'Configured';
    } else {
      statusColor = isDark ? BrandColors.nightTextSecondary : BrandColors.stone;
      statusLabel = 'Not configured';
    }

    return Row(
      children: [
        // Status dot
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        SizedBox(width: Spacing.sm),
        Icon(icon, size: 18, color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
        SizedBox(width: Spacing.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
              ),
              Text(
                botName ?? statusLabel,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
        if (isConfigured)
          TextButton(
            onPressed: () => _testConnection(platform),
            child: Text(
              'Test',
              style: TextStyle(
                fontSize: TypographyTokens.labelMedium,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTrustLevel(String label, dynamic level, bool isDark) {
    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.xxs),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ),
          Text(
            '${level ?? 'default'}',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}
