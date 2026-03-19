import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/credential_providers.dart';
import '../services/credential_service.dart';

/// Generic credential setup dialog rendered from a helper manifest.
///
/// Shows the available setup methods (e.g., PAT vs GitHub App) and renders
/// form fields dynamically. No per-provider hardcoding — works for any
/// helper that has a manifest.
class CredentialSetupDialog extends ConsumerStatefulWidget {
  final CredentialHelperManifest manifest;

  const CredentialSetupDialog({super.key, required this.manifest});

  @override
  ConsumerState<CredentialSetupDialog> createState() =>
      _CredentialSetupDialogState();
}

class _CredentialSetupDialogState
    extends ConsumerState<CredentialSetupDialog> {
  late SetupMethod _selectedMethod;
  final Map<String, TextEditingController> _controllers = {};
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Default to the recommended method, or the first one
    _selectedMethod = widget.manifest.setupMethods.firstWhere(
      (m) => m.recommended,
      orElse: () => widget.manifest.setupMethods.first,
    );
    _initControllers();
  }

  void _initControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    for (final field in _selectedMethod.fields) {
      _controllers[field.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onMethodChanged(SetupMethod method) {
    setState(() {
      _selectedMethod = method;
      _initControllers();
    });
  }

  Future<void> _save() async {
    // Validate required fields
    for (final field in _selectedMethod.fields) {
      final value = _controllers[field.id]?.text.trim() ?? '';
      if (field.required && value.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${field.label} is required'),
            backgroundColor: BrandColors.warning,
          ),
        );
        return;
      }
    }

    setState(() => _isSaving = true);

    final fields = <String, String>{};
    for (final field in _selectedMethod.fields) {
      fields[field.id] = _controllers[field.id]?.text.trim() ?? '';
    }

    final service = ref.read(credentialServiceProvider);
    final success = await service.setupHelper(
      name: widget.manifest.name,
      method: _selectedMethod.id,
      fields: fields,
    );

    if (mounted) {
      setState(() => _isSaving = false);
      if (success) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.manifest.displayName} configured'),
            backgroundColor: BrandColors.success,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to configure ${widget.manifest.displayName}'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final methods = widget.manifest.setupMethods;

    return AlertDialog(
      title: Text('Configure ${widget.manifest.displayName}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Description
              Text(
                widget.manifest.description,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              SizedBox(height: Spacing.lg),

              // Method selector (only if multiple methods)
              if (methods.length > 1) ...[
                Text(
                  'Authentication Method',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                SizedBox(height: Spacing.sm),
                ...methods.map(
                  (method) => _MethodOption(
                    method: method,
                    isSelected: method.id == _selectedMethod.id,
                    isDark: isDark,
                    onTap: () => _onMethodChanged(method),
                  ),
                ),
                SizedBox(height: Spacing.lg),
              ],

              // Method help text
              if (_selectedMethod.help.isNotEmpty) ...[
                Container(
                  padding: EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: (isDark
                            ? BrandColors.nightTurquoise
                            : BrandColors.turquoiseDeep)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: isDark
                            ? BrandColors.nightTurquoise
                            : BrandColors.turquoiseDeep,
                      ),
                      SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          _selectedMethod.help,
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: isDark
                                ? BrandColors.nightText
                                : BrandColors.charcoal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: Spacing.lg),
              ],

              // Dynamic fields
              ..._selectedMethod.fields.map(
                (field) => Padding(
                  padding: EdgeInsets.only(bottom: Spacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _controllers[field.id],
                        decoration: InputDecoration(
                          labelText: field.label,
                          helperText:
                              field.help.isNotEmpty ? field.help : null,
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          prefixIcon: field.type == 'secret'
                              ? const Icon(Icons.lock_outline, size: 20)
                              : null,
                        ),
                        obscureText: field.type == 'secret',
                      ),
                    ],
                  ),
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
          onPressed: _isSaving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor:
                isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// Radio-style option for selecting a setup method.
class _MethodOption extends StatelessWidget {
  final SetupMethod method;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _MethodOption({
    required this.method,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedColor =
        isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        margin: EdgeInsets.only(bottom: Spacing.xs),
        padding: EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? selectedColor.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: isSelected
                ? selectedColor
                : (isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood)
                    .withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected
                  ? selectedColor
                  : (isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood),
            ),
            SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        method.label,
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                          color: isDark
                              ? BrandColors.nightText
                              : BrandColors.charcoal,
                        ),
                      ),
                      if (method.recommended) ...[
                        SizedBox(width: Spacing.xs),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: Spacing.xs,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: BrandColors.success.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Recommended',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: BrandColors.success,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
