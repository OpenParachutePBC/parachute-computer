import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/supervisor_providers.dart';
import '../../../core/theme/design_tokens.dart';

/// Model picker with 3-option selector (Opus/Sonnet/Haiku) and 1M context toggle.
///
/// Stores short names with optional [1m] suffix (e.g., "opus[1m]", "sonnet").
/// The Claude Code CLI resolves short names to the latest version at runtime.
class ModelPickerDropdown extends ConsumerWidget {
  const ModelPickerDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentModelId =
        ref.watch(supervisorConfigProvider).valueOrNull?['default_model'] as String? ?? 'opus[1m]';

    // Parse current config: "opus[1m]" → base="opus", extended=true
    final parsed = _parseModelConfig(currentModelId);

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
              'Model',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.xs),
        Text(
          'Choose which Claude model to use for chat',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
          ),
        ),
        SizedBox(height: Spacing.md),

        // Model selector — 3 segments
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'opus',
                label: Text('Opus'),
                tooltip: 'Most capable',
              ),
              ButtonSegment(
                value: 'sonnet',
                label: Text('Sonnet'),
                tooltip: 'Balanced',
              ),
              ButtonSegment(
                value: 'haiku',
                label: Text('Haiku'),
                tooltip: 'Fastest',
              ),
            ],
            selected: {parsed.base},
            onSelectionChanged: (selected) {
              _updateModel(ref, context, selected.first, parsed.extendedContext);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
        SizedBox(height: Spacing.xs),

        // Family description
        Padding(
          padding: EdgeInsets.symmetric(horizontal: Spacing.xs),
          child: Text(
            _familyDescription(parsed.base),
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
        ),
        SizedBox(height: Spacing.md),

        // Extended context toggle
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Extended context (1M tokens)',
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightText : BrandColors.ink,
            ),
          ),
          subtitle: Text(
            'Reduces compaction for longer sessions',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
          value: parsed.extendedContext,
          onChanged: (enabled) {
            _updateModel(ref, context, parsed.base, enabled);
          },
        ),
      ],
    );
  }

  Future<void> _updateModel(
    WidgetRef ref,
    BuildContext context,
    String base,
    bool extendedContext,
  ) async {
    final modelId = extendedContext ? '$base[1m]' : base;
    try {
      await ref.read(supervisorConfigProvider.notifier).setModel(modelId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Model set to $modelId'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to update model'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  String _familyDescription(String family) {
    return switch (family) {
      'opus' => 'Most capable — best for complex reasoning and nuanced tasks',
      'sonnet' => 'Balanced — great performance at lower cost',
      'haiku' => 'Fastest — quick responses for simple tasks',
      _ => '',
    };
  }
}

/// Parsed model config value.
class _ModelConfig {
  const _ModelConfig({required this.base, required this.extendedContext});
  final String base; // "opus", "sonnet", "haiku"
  final bool extendedContext; // whether [1m] suffix is present
}

/// Parse "opus[1m]" → base="opus", extendedContext=true
/// Parse "sonnet" → base="sonnet", extendedContext=false
_ModelConfig _parseModelConfig(String modelId) {
  final bracketIndex = modelId.indexOf('[');
  if (bracketIndex != -1) {
    return _ModelConfig(
      base: modelId.substring(0, bracketIndex),
      extendedContext: true,
    );
  }
  return _ModelConfig(base: modelId, extendedContext: false);
}
