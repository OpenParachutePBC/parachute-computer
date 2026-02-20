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
          error: (error, _) => _buildFallbackPicker(context, isDark),
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
          onChanged: null,  // TODO: Add model update endpoint to main server
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

  Widget _buildFallbackPicker(BuildContext context, bool isDark) {
    // Standard Claude models when API is unavailable
    const fallbackModels = [
      ('claude-opus-4-6', 'Claude Opus 4.6', 'Most capable'),
      ('claude-sonnet-4-6', 'Claude Sonnet 4.6', 'Balanced'),
      ('claude-haiku-4-5-20251001', 'Claude Haiku 4.5', 'Fastest'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Info message
        Container(
          padding: EdgeInsets.all(Spacing.sm),
          margin: EdgeInsets.only(bottom: Spacing.md),
          decoration: BoxDecoration(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.1)
                : BrandColors.stone.withValues(alpha: 0.1),
            borderRadius: Radii.card,
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
              ),
              SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  'Using standard models (API unavailable)',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Standard model dropdown
        DropdownButtonFormField<String>(
          decoration: InputDecoration(
            hintText: 'Select a model',
            border: OutlineInputBorder(borderRadius: Radii.card),
          ),
          items: fallbackModels.map((model) {
            final (id, displayName, description) = model;
            return DropdownMenuItem(
              value: id,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.stone,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (modelId) {
            if (modelId != null) {
              // TODO: Save model to config via supervisor
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Selected: $modelId'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          },
        ),

        SizedBox(height: Spacing.md),

        // Custom model input
        Text(
          'Or enter a custom model ID:',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
          ),
        ),
        SizedBox(height: Spacing.xs),
        TextField(
          decoration: InputDecoration(
            hintText: 'claude-sonnet-4-6',
            border: OutlineInputBorder(borderRadius: Radii.card),
            suffixIcon: IconButton(
              icon: const Icon(Icons.check, size: 18),
              onPressed: () {
                // TODO: Save custom model to config
              },
            ),
          ),
          style: TextStyle(fontSize: TypographyTokens.bodySmall),
        ),
      ],
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
