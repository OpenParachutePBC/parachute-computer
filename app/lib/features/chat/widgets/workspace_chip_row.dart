import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/workspace.dart';
import '../providers/workspace_providers.dart' show workspacesProvider, activeWorkspaceProvider;

/// A row of workspace filter chips for new chat sessions.
///
/// Renders a "None" chip followed by one chip per workspace. Tapping a chip
/// updates [activeWorkspaceProvider] and calls [onSelected] so the parent
/// screen can apply workspace-specific defaults (trust level, working dir).
class WorkspaceChipRow extends ConsumerWidget {
  /// Called when a chip is tapped with the selected [Workspace], or null
  /// when the "None" chip is selected.
  final void Function(Workspace?)? onSelected;

  const WorkspaceChipRow({super.key, this.onSelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspacesAsync = ref.watch(workspacesProvider);
    final activeSlug = ref.watch(activeWorkspaceProvider).valueOrNull;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return workspacesAsync.when(
      data: (workspaces) {
        if (workspaces.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            Text(
              'Workspace',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontWeight: FontWeight.w500,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: 0,
              runSpacing: Spacing.xs,
              alignment: WrapAlignment.center,
              children: [
                _WorkspaceChip(
                  workspace: null,
                  label: 'None',
                  isSelected: activeSlug == null,
                  isDark: isDark,
                  onTap: () {
                    ref.read(activeWorkspaceProvider.notifier).setWorkspace(null);
                    onSelected?.call(null);
                  },
                ),
                ...workspaces.map((w) => _WorkspaceChip(
                  workspace: w,
                  label: w.name,
                  isSelected: activeSlug == w.slug,
                  isDark: isDark,
                  onTap: () {
                    ref.read(activeWorkspaceProvider.notifier).setWorkspace(w.slug);
                    onSelected?.call(w);
                  },
                )),
              ],
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _WorkspaceChip extends StatelessWidget {
  final Workspace? workspace;
  final String label;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _WorkspaceChip({
    required this.workspace,
    required this.label,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDark ? BrandColors.nightForest : BrandColors.forest;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.15)
                : (isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.2)),
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: isSelected ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                workspace == null ? Icons.do_not_disturb_alt : Icons.workspaces_outlined,
                size: 13,
                color: isSelected
                    ? color
                    : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? color
                      : (isDark ? BrandColors.nightText : BrandColors.charcoal),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
