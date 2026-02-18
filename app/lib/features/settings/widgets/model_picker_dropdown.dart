import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/supervisor_models.dart';
import '../../../core/providers/supervisor_providers.dart';
import '../../../core/theme/design_tokens.dart';

/// Dynamic model picker that fetches models from supervisor API.
///
/// Shows latest model per family by default, with option to show all.
class ModelPickerDropdown extends ConsumerStatefulWidget {
  const ModelPickerDropdown({super.key});

  @override
  ConsumerState<ModelPickerDropdown> createState() => _ModelPickerDropdownState();
}

class _ModelPickerDropdownState extends ConsumerState<ModelPickerDropdown> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final modelsAsync = ref.watch(availableModelsProvider(showAll: _showAll));
    final statusAsync = ref.watch(supervisorStatusNotifierProvider);

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
            const Spacer(),
            // Refresh button
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => ref.refresh(availableModelsProvider(showAll: _showAll)),
              tooltip: 'Refresh model list',
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
        modelsAsync.when(
          data: (models) {
            final currentModel = statusAsync.maybeWhen(
              data: (status) => status.configLoaded ? null : null,
              orElse: () => null,
            );

            if (models.isEmpty) {
              return _buildErrorState(context, isDark, 'No models available');
            }

            return _buildDropdown(
              context,
              models,
              currentModel,
              isDark,
            );
          },
          loading: () => const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => _buildErrorState(
            context,
            isDark,
            'Failed to load models: ${error.toString()}',
          ),
        ),

        // Show all toggle
        SizedBox(height: Spacing.sm),
        Row(
          children: [
            Checkbox(
              value: _showAll,
              onChanged: (value) {
                setState(() => _showAll = value ?? false);
              },
            ),
            Text(
              'Show all model versions',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDropdown(
    BuildContext context,
    List<ModelInfo> models,
    String? currentModelId,
    bool isDark,
  ) {
    // Find current model or default to first
    final selectedModel = currentModelId != null
        ? models.firstWhere(
            (m) => m.id == currentModelId,
            orElse: () => models.first,
          )
        : models.first;

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
        child: DropdownButton<ModelInfo>(
          value: selectedModel,
          isExpanded: true,
          dropdownColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          style: TextStyle(
            fontSize: TypographyTokens.bodyMedium,
            color: isDark ? BrandColors.nightText : BrandColors.ink,
          ),
          items: models.map((model) {
            return DropdownMenuItem<ModelInfo>(
              value: model,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      model.displayName,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        color: isDark ? BrandColors.nightText : BrandColors.ink,
                        fontWeight: model.isLatest ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (model.isLatest)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: Spacing.xs,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark ? BrandColors.nightForest : BrandColors.forest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Latest',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark ? BrandColors.nightText : BrandColors.softWhite,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  SizedBox(width: Spacing.sm),
                  Text(
                    _modelFamilyLabel(model.family),
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (model) async {
            if (model != null) {
              // Update config via supervisor
              await ref
                  .read(modelConfigProvider.notifier)
                  .updateDefaultModel(model.id, restart: true);

              // Show confirmation
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Model updated to ${model.displayName}'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, bool isDark, String message) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_outlined,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            size: 20,
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _modelFamilyLabel(String family) {
    return switch (family) {
      'opus' => 'Most capable',
      'sonnet' => 'Balanced',
      'haiku' => 'Fastest',
      _ => family,
    };
  }
}
