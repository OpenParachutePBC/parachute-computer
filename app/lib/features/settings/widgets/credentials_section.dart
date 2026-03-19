import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/credential_providers.dart';
import '../services/credential_service.dart';
import 'credential_setup_dialog.dart';

/// Settings section showing configured credential helpers with status.
///
/// Renders entirely from server manifests — no per-provider hardcoding.
/// Each helper shows its display name, active method, and injected env vars.
/// Tap to reconfigure, long-press to remove.
class CredentialsSection extends ConsumerWidget {
  const CredentialsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final helpersAsync = ref.watch(credentialHelpersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.shield_outlined,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Credentials',
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
          'Service credentials injected into sandbox environments.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Helper list
        helpersAsync.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (_, __) => _OfflineMessage(isDark: isDark),
          data: (helpers) {
            if (helpers.isEmpty) {
              return _EmptyState(
                isDark: isDark,
                onAdd: () => _showAddHelper(context, ref),
              );
            }
            return Column(
              children: [
                ...helpers.entries.map(
                  (entry) => _HelperCard(
                    name: entry.key,
                    manifest: entry.value,
                    isDark: isDark,
                    onTap: () => _showSetupDialog(context, ref, entry.value),
                    onRemove: () => _removeHelper(context, ref, entry.key, entry.value.displayName),
                  ),
                ),
                SizedBox(height: Spacing.md),
                _AddHelperButton(
                  isDark: isDark,
                  onTap: () => _showAddHelper(context, ref),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  void _showSetupDialog(
    BuildContext context,
    WidgetRef ref,
    CredentialHelperManifest manifest,
  ) {
    showDialog(
      context: context,
      builder: (_) => CredentialSetupDialog(manifest: manifest),
    ).then((result) {
      if (result == true) {
        ref.invalidate(credentialHelpersProvider);
      }
    });
  }

  void _showAddHelper(BuildContext context, WidgetRef ref) {
    // Show a simple dialog to add env-passthrough credentials
    showDialog(
      context: context,
      builder: (_) => const _AddGenericHelperDialog(),
    ).then((result) {
      if (result == true) {
        ref.invalidate(credentialHelpersProvider);
      }
    });
  }

  Future<void> _removeHelper(
    BuildContext context,
    WidgetRef ref,
    String name,
    String displayName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Credential?'),
        content: Text(
          'Remove $displayName? The sandbox will no longer have access to this credential.',
        ),
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

    if (confirmed != true || !context.mounted) return;

    final service = ref.read(credentialServiceProvider);
    final success = await service.removeHelper(name);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? '$displayName removed' : 'Failed to remove $displayName',
          ),
          backgroundColor: success ? BrandColors.success : BrandColors.error,
        ),
      );
      if (success) ref.invalidate(credentialHelpersProvider);
    }
  }
}

/// Card showing a configured credential helper.
class _HelperCard extends StatelessWidget {
  final String name;
  final CredentialHelperManifest manifest;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _HelperCard({
    required this.name,
    required this.manifest,
    required this.isDark,
    required this.onTap,
    required this.onRemove,
  });

  IconData _iconForHelper(String name) {
    switch (name) {
      case 'github':
        return Icons.code;
      case 'cloudflare':
        return Icons.cloud_outlined;
      default:
        return Icons.vpn_key_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConfigured = manifest.configured;
    final statusColor = isConfigured ? BrandColors.success : BrandColors.warning;

    return Container(
      margin: EdgeInsets.only(bottom: Spacing.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          padding: EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: isDark ? BrandColors.nightSurface : BrandColors.cream,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                  : BrandColors.driftwood.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(
                _iconForHelper(name),
                size: 24,
                color: statusColor,
              ),
              SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest.displayName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                    SizedBox(height: Spacing.xxs),
                    if (manifest.activeMethod != null)
                      Text(
                        manifest.activeMethod!,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                    if (manifest.provides.envVars.isNotEmpty) ...[
                      SizedBox(height: Spacing.xxs),
                      Wrap(
                        spacing: Spacing.xs,
                        children: manifest.provides.envVars
                            .map(
                              (v) => Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: Spacing.xs,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: (isDark
                                          ? BrandColors.nightTextSecondary
                                          : BrandColors.driftwood)
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  v,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    color: isDark
                                        ? BrandColors.nightTextSecondary
                                        : BrandColors.driftwood,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: BrandColors.error.withValues(alpha: 0.7),
                ),
                onPressed: onRemove,
                tooltip: 'Remove',
              ),
              Icon(
                Icons.chevron_right,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty state when no credentials are configured.
class _EmptyState extends StatelessWidget {
  final bool isDark;
  final VoidCallback onAdd;

  const _EmptyState({required this.isDark, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        children: [
          Icon(
            Icons.shield_outlined,
            size: 32,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'No credentials configured',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Add credentials so sandboxed agents can access GitHub, Cloudflare, and other services.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.md),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Credential'),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
        ],
      ),
    );
  }
}

/// Button to add a new credential helper.
class _AddHelperButton extends StatelessWidget {
  final bool isDark;
  final VoidCallback onTap;

  const _AddHelperButton({required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add Credential'),
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          side: BorderSide(
            color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                .withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Offline message when server isn't reachable.
class _OfflineMessage extends StatelessWidget {
  final bool isDark;

  const _OfflineMessage({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Connect to server to manage credentials',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog for adding a generic env-passthrough credential.
class _AddGenericHelperDialog extends ConsumerStatefulWidget {
  const _AddGenericHelperDialog();

  @override
  ConsumerState<_AddGenericHelperDialog> createState() =>
      _AddGenericHelperDialogState();
}

class _AddGenericHelperDialogState
    extends ConsumerState<_AddGenericHelperDialog> {
  final _nameController = TextEditingController();
  final _envVarController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _envVarController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim().toLowerCase();
    final envVar = _envVarController.text.trim();
    final token = _tokenController.text.trim();

    if (name.isEmpty || envVar.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All fields are required'),
          backgroundColor: BrandColors.warning,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    final service = ref.read(credentialServiceProvider);
    final success = await service.setupHelper(
      name: name,
      method: 'env-passthrough',
      fields: {'env_var': envVar, 'token': token},
    );

    if (mounted) {
      setState(() => _isSaving = false);
      if (success) {
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save credential'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Credential'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g., vercel',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: Spacing.md),
            TextField(
              controller: _envVarController,
              decoration: const InputDecoration(
                labelText: 'Environment Variable',
                hintText: 'e.g., VERCEL_TOKEN',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: Spacing.md),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Token',
                hintText: 'Paste your token',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
