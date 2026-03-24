import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';

import '../providers/api_providers_provider.dart';

/// Settings section for managing API providers (bring your own backend).
///
/// Lets users add Anthropic-compatible API endpoints (e.g., Moonshot/Kimi K2.5)
/// and switch between them.
class ProviderSection extends ConsumerStatefulWidget {
  const ProviderSection({super.key});

  @override
  ConsumerState<ProviderSection> createState() => _ProviderSectionState();
}

class _ProviderSectionState extends ConsumerState<ProviderSection> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final providersAsync = ref.watch(apiProvidersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'API Provider',
                style: TextStyle(
                  fontSize: TypographyTokens.titleMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
            // Add button
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: 'Add provider',
              onPressed: () => _showAddDialog(context, isDark),
              style: IconButton.styleFrom(
                foregroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.xs),
        Text(
          'Switch between Anthropic and third-party API endpoints',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
          ),
        ),
        SizedBox(height: Spacing.md),

        // Provider list
        providersAsync.when(
          data: (state) => _buildProviderList(context, state, isDark),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text(
            'Could not load providers',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProviderList(
    BuildContext context,
    ApiProvidersState state,
    bool isDark,
  ) {
    return Column(
      children: [
        // Anthropic default — always shown
        _ProviderTile(
          label: 'Anthropic (default)',
          subtitle: 'Uses Claude subscription or OAuth token',
          isActive: state.active == null,
          isDark: isDark,
          onTap: () => _setActive(null),
        ),

        // Custom providers
        ...state.providers.map((p) => _ProviderTile(
              label: p.label,
              subtitle: p.defaultModel != null
                  ? '${p.baseUrl}  \u00b7  ${p.defaultModel}'
                  : p.baseUrl,
              keyHint: p.keyHint,
              isActive: p.name == state.active,
              isDark: isDark,
              onTap: () => _setActive(p.name),
              onDelete: () => _confirmDelete(context, p.name, p.label, isDark),
            )),
      ],
    );
  }

  Future<void> _setActive(String? name) async {
    try {
      await ref.read(apiProvidersProvider.notifier).setActive(name);
      if (mounted) {
        final label = name ?? 'Anthropic (default)';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Switched to $label'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to switch provider: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    String name,
    String label,
    bool isDark,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Provider?'),
        content: Text('Remove "$label"? You can add it back later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await ref.read(apiProvidersProvider.notifier).removeProvider(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed $label'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove provider: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _showAddDialog(BuildContext context, bool isDark) async {
    final nameController = TextEditingController();
    final labelController = TextEditingController();
    final urlController = TextEditingController();
    final keyController = TextEditingController();
    final modelController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _AddProviderDialog(
        nameController: nameController,
        labelController: labelController,
        urlController: urlController,
        keyController: keyController,
        modelController: modelController,
        isDark: isDark,
      ),
    );

    if (result != true || !mounted) return;

    final name = nameController.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '-');
    if (name.isEmpty || urlController.text.trim().isEmpty || keyController.text.trim().isEmpty) return;

    try {
      await ref.read(apiProvidersProvider.notifier).addProvider(
            name: name,
            providerBaseUrl: urlController.text.trim(),
            apiKey: keyController.text.trim(),
            label: labelController.text.trim().isEmpty ? null : labelController.text.trim(),
            defaultModel: modelController.text.trim().isEmpty ? null : modelController.text.trim(),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${labelController.text.trim().isEmpty ? name : labelController.text.trim()}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add provider: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    nameController.dispose();
    labelController.dispose();
    urlController.dispose();
    keyController.dispose();
    modelController.dispose();
  }
}

/// A single provider row with active indicator and optional delete.
class _ProviderTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final String? keyHint;
  final bool isActive;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _ProviderTile({
    required this.label,
    required this.subtitle,
    required this.isActive,
    required this.isDark,
    required this.onTap,
    this.keyHint,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final activeBorder = isActive
        ? Border.all(
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
            width: 1.5,
          )
        : Border.all(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.driftwood.withValues(alpha: 0.2),
          );

    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          padding: EdgeInsets.all(Spacing.sm),
          decoration: BoxDecoration(
            color: isActive
                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                    .withValues(alpha: 0.08)
                : null,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: activeBorder,
          ),
          child: Row(
            children: [
              // Active indicator
              Icon(
                isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: isActive
                    ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                    : (isDark ? BrandColors.nightTextSecondary : BrandColors.stone),
              ),
              SizedBox(width: Spacing.sm),
              // Label + subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                        fontSize: TypographyTokens.bodyMedium,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Delete button (not for Anthropic default)
              if (onDelete != null)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  ),
                  onPressed: onDelete,
                  tooltip: 'Remove provider',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog for adding a new API provider.
class _AddProviderDialog extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController labelController;
  final TextEditingController urlController;
  final TextEditingController keyController;
  final TextEditingController modelController;
  final bool isDark;

  const _AddProviderDialog({
    required this.nameController,
    required this.labelController,
    required this.urlController,
    required this.keyController,
    required this.modelController,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add API Provider'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelController,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  hintText: 'e.g., Kimi K2.5 (Moonshot)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                autofocus: true,
              ),
              SizedBox(height: Spacing.md),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Slug (lowercase, no spaces)',
                  hintText: 'e.g., moonshot',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              SizedBox(height: Spacing.md),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL *',
                  hintText: 'https://api.moonshot.ai/anthropic',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
              ),
              SizedBox(height: Spacing.md),
              TextField(
                controller: keyController,
                decoration: const InputDecoration(
                  labelText: 'API Key *',
                  hintText: 'sk-...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                obscureText: true,
              ),
              SizedBox(height: Spacing.md),
              TextField(
                controller: modelController,
                decoration: const InputDecoration(
                  labelText: 'Default model (optional)',
                  hintText: 'e.g., kimi-k2.5',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
