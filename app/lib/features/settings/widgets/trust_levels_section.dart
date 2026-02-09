import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import '../models/trust_level.dart';

/// Shows per-module trust levels and Docker sandbox status.
class TrustLevelsSection extends ConsumerStatefulWidget {
  const TrustLevelsSection({super.key});

  @override
  ConsumerState<TrustLevelsSection> createState() => _TrustLevelsSectionState();
}

class _TrustLevelsSectionState extends ConsumerState<TrustLevelsSection> {
  List<Map<String, dynamic>>? _modules;
  Map<String, dynamic>? _dockerStatus;
  bool _isLoading = true;
  bool _isBuilding = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
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

      final results = await Future.wait([
        http.get(Uri.parse('$serverUrl/api/modules'), headers: headers)
            .timeout(const Duration(seconds: 5)),
        http.get(Uri.parse('$serverUrl/api/health?detailed=true'), headers: headers)
            .timeout(const Duration(seconds: 10)),
      ]);
      final modulesResponse = results[0];
      final healthResponse = results[1];

      if (mounted) {
        if (modulesResponse.statusCode == 200) {
          final data = json.decode(modulesResponse.body) as Map<String, dynamic>;
          setState(() {
            _modules = (data['modules'] as List?)?.cast<Map<String, dynamic>>();
          });
        }
        if (healthResponse.statusCode == 200) {
          final data = json.decode(healthResponse.body) as Map<String, dynamic>;
          setState(() {
            _dockerStatus = data['docker'] as Map<String, dynamic>?;
          });
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load module status: $e';
          _isLoading = false;
        });
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
              Icons.security_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Trust Levels',
                style: TextStyle(
                  fontSize: TypographyTokens.titleMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
            // Refresh button
            IconButton(
              onPressed: _isLoading ? null : _loadData,
              icon: Icon(
                Icons.refresh,
                size: 18,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              tooltip: 'Refresh',
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
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
          // Docker status
          _buildDockerStatus(isDark),
          SizedBox(height: Spacing.lg),

          // Module trust levels
          if (_modules != null && _modules!.isNotEmpty) ...[
            Text(
              'Module Defaults',
              style: TextStyle(
                fontSize: TypographyTokens.labelLarge,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            SizedBox(height: Spacing.sm),
            ..._modules!.map((m) => _buildModuleRow(m, isDark)),
          ] else
            Text(
              'No modules loaded',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),

          // Footer
          SizedBox(height: Spacing.md),
          Text(
            'Docker required for Untrusted sessions',
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

  Future<void> _buildSandboxImage() async {
    setState(() => _isBuilding = true);

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final request = http.Request(
        'POST',
        Uri.parse('$serverUrl/api/sandbox/build'),
      );
      if (apiKey != null && apiKey.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }

      final client = http.Client();
      try {
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw Exception('Build request failed: ${response.statusCode}');
        }

        // Process SSE stream incrementally to avoid buffering entire response
        bool hasError = false;
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          if (chunk.contains('"build_error"')) {
            hasError = true;
          }
        }

        if (mounted) {
          if (hasError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Sandbox image build failed'),
                backgroundColor: BrandColors.error,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Sandbox image built successfully'),
                backgroundColor: BrandColors.forest,
              ),
            );
          }
          await _loadData(); // Refresh status
        }
      } finally {
        client.close();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Build failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isBuilding = false);
      }
    }
  }

  Widget _buildDockerStatus(bool isDark) {
    final available = _dockerStatus?['available'] == true;
    final imageExists = _dockerStatus?['image_exists'] == true;

    Color statusColor;
    String statusLabel;
    if (available && imageExists) {
      statusColor = BrandColors.forest;
      statusLabel = 'Docker ready (sandbox image built)';
    } else if (available) {
      statusColor = BrandColors.warning;
      statusLabel = 'Docker available (sandbox image not built)';
    } else {
      statusColor = isDark ? BrandColors.nightTextSecondary : BrandColors.stone;
      statusLabel = 'Docker not available';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: Spacing.sm),
            Icon(
              Icons.dns_outlined,
              size: 18,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            SizedBox(width: Spacing.xs),
            Expanded(
              child: Text(
                statusLabel,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
              ),
            ),
            // Build button when Docker available but image not built
            if (available && !imageExists)
              TextButton.icon(
                onPressed: _isBuilding ? null : _buildSandboxImage,
                icon: _isBuilding
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark ? BrandColors.nightForest : BrandColors.forest,
                        ),
                      )
                    : Icon(
                        Icons.build_outlined,
                        size: 14,
                        color: isDark ? BrandColors.nightForest : BrandColors.forest,
                      ),
                label: Text(
                  _isBuilding ? 'Building...' : 'Build Image',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ),
          ],
        ),
        if (_isBuilding)
          Padding(
            padding: EdgeInsets.only(top: Spacing.xs),
            child: LinearProgressIndicator(
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
              backgroundColor: (isDark ? BrandColors.nightForest : BrandColors.forest)
                  .withValues(alpha: 0.15),
            ),
          ),
      ],
    );
  }

  Widget _buildModuleRow(Map<String, dynamic> module, bool isDark) {
    final name = module['name'] as String? ?? 'unknown';
    final trustLevelStr = module['trust_level'] as String? ?? 'trusted';
    final trustLevel = TrustLevel.fromString(trustLevelStr);

    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        children: [
          // Module name
          SizedBox(
            width: 80,
            child: Text(
              name,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                fontWeight: FontWeight.w500,
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
            ),
          ),
          // Trust level badge
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: trustLevel.iconColor(isDark).withValues(alpha: 0.15),
              borderRadius: Radii.badge,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  trustLevel.icon,
                  size: 12,
                  color: trustLevel.iconColor(isDark),
                ),
                SizedBox(width: Spacing.xxs),
                Text(
                  trustLevel.displayName,
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    fontWeight: FontWeight.w500,
                    color: trustLevel.iconColor(isDark),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
