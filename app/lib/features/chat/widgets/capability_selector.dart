import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/agent_providers.dart';
import '../providers/skill_providers.dart';
import '../providers/mcp_providers.dart';
import '../models/workspace.dart';

/// Editor for workspace capabilities (agents, skills, MCP servers).
///
/// Shows three sections with All/None/Custom toggles. When "Custom" is
/// selected, shows checkboxes for available items.
class CapabilitiesEditor extends ConsumerWidget {
  final WorkspaceCapabilities capabilities;
  final ValueChanged<WorkspaceCapabilities> onChanged;

  const CapabilitiesEditor({
    super.key,
    required this.capabilities,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final agents = ref.watch(agentsProvider);
    final skills = ref.watch(skillsProvider);
    final mcps = ref.watch(mcpServersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Capabilities',
          style: TextStyle(
            fontSize: TypographyTokens.titleSmall,
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.sm),
        _CapabilitySection(
          label: 'Agents',
          value: capabilities.agents,
          availableNames: agents.whenOrNull(
            data: (list) => list.map((a) => a.name).toList(),
          ),
          onChanged: (val) => onChanged(WorkspaceCapabilities(
            mcps: capabilities.mcps,
            skills: capabilities.skills,
            agents: val,
          )),
          isDark: isDark,
        ),
        SizedBox(height: Spacing.sm),
        _CapabilitySection(
          label: 'Skills',
          value: capabilities.skills,
          availableNames: skills.whenOrNull(
            data: (list) => list.map((s) => s.name).toList(),
          ),
          onChanged: (val) => onChanged(WorkspaceCapabilities(
            mcps: capabilities.mcps,
            skills: val,
            agents: capabilities.agents,
          )),
          isDark: isDark,
        ),
        SizedBox(height: Spacing.sm),
        _CapabilitySection(
          label: 'MCP Servers',
          value: capabilities.mcps,
          availableNames: mcps.whenOrNull(
            data: (list) => list.map((m) => m.name).toList(),
          ),
          onChanged: (val) => onChanged(WorkspaceCapabilities(
            mcps: val,
            skills: capabilities.skills,
            agents: capabilities.agents,
          )),
          isDark: isDark,
        ),
      ],
    );
  }
}

/// A single capability type section with All/None/Custom toggle.
class _CapabilitySection extends StatelessWidget {
  final String label;
  final dynamic value; // "all", "none", or List<String>
  final List<String>? availableNames;
  final ValueChanged<dynamic> onChanged;
  final bool isDark;

  const _CapabilitySection({
    required this.label,
    required this.value,
    required this.availableNames,
    required this.onChanged,
    required this.isDark,
  });

  String get _mode {
    if (value is String) return value as String;
    return 'custom';
  }

  List<String> get _selectedNames {
    if (value is List) return (value as List).cast<String>();
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  fontWeight: FontWeight.w500,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('All')),
                ButtonSegment(value: 'none', label: Text('None')),
                ButtonSegment(value: 'custom', label: Text('Custom')),
              ],
              selected: {_mode},
              onSelectionChanged: (selected) {
                final mode = selected.first;
                if (mode == 'all' || mode == 'none') {
                  onChanged(mode);
                } else {
                  // Switch to custom with all selected by default
                  onChanged(List<String>.from(availableNames ?? []));
                }
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: TypographyTokens.labelSmall),
                ),
              ),
            ),
          ],
        ),
        if (_mode == 'custom' && availableNames != null) ...[
          SizedBox(height: Spacing.xs),
          ...availableNames!.map((name) {
            final selected = _selectedNames.contains(name);
            return InkWell(
              onTap: () {
                final updated = List<String>.from(_selectedNames);
                if (selected) {
                  updated.remove(name);
                } else {
                  updated.add(name);
                }
                onChanged(updated);
              },
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: selected,
                        onChanged: (val) {
                          final updated = List<String>.from(_selectedNames);
                          if (val == true) {
                            updated.add(name);
                          } else {
                            updated.remove(name);
                          }
                          onChanged(updated);
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    SizedBox(width: Spacing.xs),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}
