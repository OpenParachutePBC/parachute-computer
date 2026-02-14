import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show ClaudeModel, modelPreferenceProvider;

/// Settings section for selecting the Claude model.
class ModelSelectionSection extends ConsumerWidget {
  const ModelSelectionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final modelAsync = ref.watch(modelPreferenceProvider);

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

        // Model dropdown
        modelAsync.when(
          data: (currentModel) => _buildDropdown(context, ref, currentModel, isDark),
          loading: () => const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _buildDropdown(context, ref, ClaudeModel.sonnet, isDark),
        ),
      ],
    );
  }

  Widget _buildDropdown(
    BuildContext context,
    WidgetRef ref,
    ClaudeModel currentModel,
    bool isDark,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.md),
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
        borderRadius: Radii.card,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ClaudeModel>(
          value: currentModel,
          isExpanded: true,
          dropdownColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          style: TextStyle(
            fontSize: TypographyTokens.bodyMedium,
            color: isDark ? BrandColors.nightText : BrandColors.ink,
          ),
          items: ClaudeModel.values.map((model) {
            return DropdownMenuItem<ClaudeModel>(
              value: model,
              child: Row(
                children: [
                  Text(
                    model.displayName,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightText : BrandColors.ink,
                    ),
                  ),
                  SizedBox(width: Spacing.sm),
                  Text(
                    _modelDescription(model),
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.stone,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (model) {
            if (model != null) {
              ref.read(modelPreferenceProvider.notifier).setModel(model);
            }
          },
        ),
      ),
    );
  }

  String _modelDescription(ClaudeModel model) {
    return switch (model) {
      ClaudeModel.sonnet => 'Balanced',
      ClaudeModel.opus => 'Most capable',
      ClaudeModel.haiku => 'Fastest',
    };
  }
}
