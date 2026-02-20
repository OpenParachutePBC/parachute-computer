import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';

/// Hooks visibility section — shows registered hooks and recent errors.
class HooksSection extends ConsumerStatefulWidget {
  const HooksSection({super.key});

  @override
  ConsumerState<HooksSection> createState() => _HooksSectionState();
}

class _HooksSectionState extends ConsumerState<HooksSection> {
  List<Map<String, dynamic>>? _hooks;
  int _recentErrors = 0;
  bool _isLoading = false;
  String? _error;
  bool _errorsExpanded = false;
  List<Map<String, dynamic>>? _errorDetails;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHooks());
  }

  Future<void> _loadHooks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.get(
        Uri.parse('$serverUrl/api/hooks'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        if (response.statusCode == 200) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          setState(() {
            _hooks = List<Map<String, dynamic>>.from(data['hooks'] ?? []);
            final health = data['health'] as Map<String, dynamic>? ?? {};
            _recentErrors = health['recent_errors_count'] as int? ?? 0;
            _isLoading = false;
          });
        } else {
          setState(() {
            _error = 'Failed to load hooks: ${response.statusCode}';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load hooks: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadErrors() async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.get(
        Uri.parse('$serverUrl/api/hooks/errors'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted && response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _errorDetails = List<Map<String, dynamic>>.from(data['errors'] ?? []);
        });
      }
    } catch (_) {
      // Silently fail — errors section is secondary
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
              Icons.webhook_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Hooks',
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
        else if (_hooks == null || _hooks!.isEmpty)
          Text(
            'No hooks configured. Add hooks to .claude/settings.json',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              fontStyle: FontStyle.italic,
            ),
          )
        else ...[
          // Health summary
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.cream,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                Icon(
                  _recentErrors > 0 ? Icons.warning_amber : Icons.check_circle_outline,
                  size: 16,
                  color: _recentErrors > 0 ? BrandColors.warning : BrandColors.forest,
                ),
                SizedBox(width: Spacing.xs),
                Text(
                  '${_hooks!.length} hooks registered${_recentErrors > 0 ? ', $_recentErrors recent errors' : ''}',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),

          // Hook list
          ..._hooks!.map((hook) => _buildHookRow(hook, isDark)),

          // Expandable errors
          if (_recentErrors > 0) ...[
            SizedBox(height: Spacing.md),
            InkWell(
              onTap: () {
                setState(() => _errorsExpanded = !_errorsExpanded);
                if (_errorsExpanded && _errorDetails == null) {
                  _loadErrors();
                }
              },
              child: Row(
                children: [
                  Icon(
                    _errorsExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: BrandColors.warning,
                  ),
                  SizedBox(width: Spacing.xxs),
                  Text(
                    'Recent Errors ($_recentErrors)',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelMedium,
                      fontWeight: FontWeight.w500,
                      color: BrandColors.warning,
                    ),
                  ),
                ],
              ),
            ),
            if (_errorsExpanded && _errorDetails != null)
              ..._errorDetails!.map((err) => _buildErrorRow(err, isDark)),
          ],
        ],
      ],
    );
  }

  Widget _buildHookRow(Map<String, dynamic> hook, bool isDark) {
    final name = hook['name'] as String? ?? 'unnamed';
    final events = (hook['events'] as List<dynamic>?)?.cast<String>() ?? [];
    final blocking = hook['blocking'] == true;
    final description = hook['description'] as String?;

    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    fontWeight: FontWeight.w500,
                    color: isDark ? BrandColors.nightText : BrandColors.ink,
                  ),
                ),
              ),
              if (blocking)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
                  decoration: BoxDecoration(
                    color: BrandColors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(
                    'blocking',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: BrandColors.warning,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
          if (events.isNotEmpty) ...[
            SizedBox(height: Spacing.xxs),
            Wrap(
              spacing: Spacing.xxs,
              runSpacing: Spacing.xxs,
              children: events.map((event) => Container(
                padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 1),
                decoration: BoxDecoration(
                  color: isDark
                      ? BrandColors.nightForest.withValues(alpha: 0.15)
                      : BrandColors.forestMist,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  event,
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              )).toList(),
            ),
          ],
          if (description != null) ...[
            SizedBox(height: Spacing.xxs),
            Text(
              description,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorRow(Map<String, dynamic> err, bool isDark) {
    final hook = err['hook'] as String? ?? '';
    final message = err['message'] as String? ?? '';
    final timestamp = err['timestamp'] as String? ?? '';

    return Padding(
      padding: EdgeInsets.only(left: Spacing.md, top: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 14, color: BrandColors.error),
              SizedBox(width: Spacing.xxs),
              Text(
                hook,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
              ),
              if (timestamp.isNotEmpty) ...[
                const Spacer(),
                Text(
                  timestamp,
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  ),
                ),
              ],
            ],
          ),
          if (message.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: Spacing.md),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: BrandColors.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
