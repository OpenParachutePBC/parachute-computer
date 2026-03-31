import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/daily_agent_models.dart'
    show AgentTemplate, DailyAgentInfo, MemoryMode;
import '../providers/journal_providers.dart';
import '../utils/time_helpers.dart';

/// Tool definition for the context sources UI.
class _ToolDef {
  final String key;
  final String label;
  final String description;
  final IconData icon;
  const _ToolDef(this.key, this.label, this.description, this.icon);
}

/// Tools for scheduled (day-scoped) Agents — operate across a day's entries.
const _scheduledTools = [
  _ToolDef(
    'read_journal',
    "Today's journal",
    'Read all journal entries for today',
    Icons.today,
  ),
  _ToolDef(
    'read_recent_journals',
    'Recent journals',
    'Read journal entries from the past 7 days',
    Icons.date_range,
  ),
  _ToolDef(
    'read_chat_log',
    'Chat logs',
    'Read AI chat logs for today',
    Icons.chat_outlined,
  ),
  _ToolDef(
    'read_recent_sessions',
    'Recent chat sessions',
    'Read AI chat sessions from the past 7 days',
    Icons.forum_outlined,
  ),
];

/// Tools for triggered (note-scoped) Agents — operate on a single note.
const _triggeredTools = [
  _ToolDef(
    'read_entry',
    'Read note',
    'Read the note that triggered this agent',
    Icons.article_outlined,
  ),
  _ToolDef(
    'update_entry_content',
    'Update content',
    'Replace the note content with processed text',
    Icons.edit_note,
  ),
  _ToolDef(
    'update_entry_tags',
    'Update tags',
    'Set tags on the note',
    Icons.label_outlined,
  ),
];

/// Full-screen form for creating or editing an Agent.
///
/// Pass [agent] for edit mode, or [template] for creating from a template.
/// Both null = blank creation.
class AgentEditScreen extends ConsumerStatefulWidget {
  /// Non-null when editing an existing agent.
  final DailyAgentInfo? agent;

  /// Non-null when creating from a template.
  final AgentTemplate? template;

  const AgentEditScreen({super.key, this.agent, this.template});

  bool get isEditing => agent != null;

  @override
  ConsumerState<AgentEditScreen> createState() => _AgentEditScreenState();
}

class _AgentEditScreenState extends ConsumerState<AgentEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _promptController;
  late Set<String> _enabledTools;
  late bool _scheduleEnabled;
  late String _scheduleTime;
  late MemoryMode _memoryMode;
  late String _containerSlug;
  bool _isSaving = false;

  /// Whether this Agent is event-driven (triggered) rather than scheduled.
  bool get _isTriggered {
    if (widget.isEditing) return widget.agent!.isTriggered;
    if (widget.template != null) return widget.template!.isTriggered;
    return false;
  }

  /// Available tools based on the Agent type.
  List<_ToolDef> get _availableTools =>
      _isTriggered ? _triggeredTools : _scheduledTools;

  @override
  void initState() {
    super.initState();

    if (widget.isEditing) {
      // Edit mode — populate from existing agent
      final c = widget.agent!;
      _nameController = TextEditingController(text: c.displayName);
      _descriptionController = TextEditingController(text: c.description);
      _promptController = TextEditingController(text: c.systemPrompt);
      _enabledTools = Set.from(c.tools);
      _scheduleEnabled = c.scheduleEnabled;
      _scheduleTime = c.scheduleTime;
      _memoryMode = c.memoryMode;
      _containerSlug = c.containerSlug;
    } else if (widget.template != null) {
      // Template mode — populate from template
      final t = widget.template!;
      _nameController = TextEditingController(text: t.displayName);
      _descriptionController = TextEditingController(text: t.description);
      _promptController = TextEditingController(text: t.systemPrompt);
      _enabledTools = Set.from(t.tools);
      _scheduleEnabled = false; // Templates start unscheduled
      _scheduleTime = t.scheduleTime;
      _memoryMode = t.memoryMode;
      _containerSlug = '';
    } else {
      // Blank creation
      _nameController = TextEditingController();
      _descriptionController = TextEditingController();
      _promptController = TextEditingController();
      _enabledTools = {'read_journal', 'read_recent_journals'};
      _scheduleEnabled = false;
      _scheduleTime = '21:00';
      _memoryMode = MemoryMode.persistent;
      _containerSlug = '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  /// Convert display name to a slug for the agent name field.
  String _toSlug(String displayName) {
    return displayName
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final title = widget.isEditing ? 'Edit Agent' : 'New Agent';

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: isDark
            ? BrandColors.nightSurface
            : BrandColors.softWhite,
        foregroundColor: isDark ? BrandColors.softWhite : BrandColors.ink,
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          Padding(
            padding: EdgeInsets.only(right: Spacing.sm),
            child: FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(widget.isEditing ? 'Save' : 'Create'),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.md,
          ),
          children: [
            // ── Builtin notice ────────────────────────────────────────
            if (widget.isEditing && widget.agent!.isBuiltin) ...[
              Container(
                padding: EdgeInsets.all(Spacing.md),
                decoration: BoxDecoration(
                  color: isDark
                      ? BrandColors.info.withValues(alpha: 0.1)
                      : BrandColors.info.withValues(alpha: 0.08),
                  borderRadius: Radii.card,
                  border: Border.all(
                    color: BrandColors.info.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: BrandColors.info),
                    SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        'Saving changes will mark this as customized. '
                        'You can reset to the default later.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: BrandColors.info,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Spacing.lg),
            ],

            // ── Name & Description ────────────────────────────────────
            Text(
              'Identity',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.sm),
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Daily Reflection',
                filled: true,
                fillColor: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.softWhite,
              ),
              textCapitalization: TextCapitalization.words,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            SizedBox(height: Spacing.md),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: 'Description',
                hintText: 'What does this agent do?',
                filled: true,
                fillColor: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.softWhite,
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
            ),

            // ── System Prompt ─────────────────────────────────────────
            SizedBox(height: Spacing.xl),
            Text(
              'System Prompt',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              'Use {user_name} and {user_context} as template variables.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            TextFormField(
              controller: _promptController,
              decoration: InputDecoration(
                hintText: 'Write the system prompt for this agent...',
                filled: true,
                fillColor: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.softWhite,
                alignLabelWithHint: true,
              ),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
              maxLines: null,
              minLines: 8,
              textCapitalization: TextCapitalization.sentences,
            ),

            // ── Context Sources ───────────────────────────────────────
            SizedBox(height: Spacing.xl),
            Text(
              _isTriggered ? 'Tools' : 'Context Sources',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              _isTriggered
                  ? 'Choose what this agent can do with the note.'
                  : 'Choose what information this agent can access.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            ..._availableTools.map(
              (tool) => _ToolToggle(
                tool: tool,
                enabled: _enabledTools.contains(tool.key),
                isDark: isDark,
                onChanged: (enabled) {
                  setState(() {
                    if (enabled) {
                      _enabledTools.add(tool.key);
                    } else {
                      _enabledTools.remove(tool.key);
                    }
                  });
                },
              ),
            ),

            // ── Memory Mode ───────────────────────────────────────────
            SizedBox(height: Spacing.xl),
            Text(
              'Memory',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              _memoryMode == MemoryMode.persistent
                  ? 'Agent remembers previous runs and builds on them.'
                  : 'Agent starts fresh each run with no memory of prior runs.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.sm,
              ),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.softWhite,
                borderRadius: Radii.button,
              ),
              child: Row(
                children: [
                  Icon(
                    _memoryMode == MemoryMode.persistent
                        ? Icons.psychology
                        : Icons.restart_alt,
                    size: 20,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      _memoryMode == MemoryMode.persistent
                          ? 'Persistent memory'
                          : 'Fresh each run',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: _memoryMode == MemoryMode.persistent,
                    onChanged: (persistent) {
                      setState(() {
                        _memoryMode = persistent ? MemoryMode.persistent : MemoryMode.fresh;
                      });
                    },
                    activeColor: isDark
                        ? BrandColors.nightForest
                        : BrandColors.forest,
                  ),
                ],
              ),
            ),

            // ── Container ────────────────────────────────────────────
            SizedBox(height: Spacing.xl),
            Text(
              'Container',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              _containerSlug.isEmpty
                  ? 'Agent runs in its own dedicated container.'
                  : 'Agent runs in the "$_containerSlug" workspace.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            _ContainerPicker(
              selectedSlug: _containerSlug,
              isDark: isDark,
              onChanged: (slug) => setState(() => _containerSlug = slug),
            ),

            // ── Schedule (only for scheduled Agents) ──────────────────
            if (!_isTriggered) ...[
              SizedBox(height: Spacing.xl),
              Text(
                'Schedule',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                ),
              ),
              SizedBox(height: Spacing.sm),
              _ScheduleConfig(
                enabled: _scheduleEnabled,
                time: _scheduleTime,
                isDark: isDark,
                onToggle: (enabled) =>
                    setState(() => _scheduleEnabled = enabled),
                onTimeTap: _pickTime,
              ),
            ],

            // Bottom padding
            SizedBox(height: Spacing.xxl),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: parseHHMM(_scheduleTime),
    );
    if (picked == null || !mounted) return;

    setState(() => _scheduleTime = formatTimeOfDay(picked));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final api = ref.read(dailyApiServiceProvider);
    final displayName = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final prompt = _promptController.text;
    final tools = _enabledTools.toList();

    bool success;

    if (widget.isEditing) {
      // Update existing tool — preserve trigger fields
      final fields = <String, dynamic>{
        'display_name': displayName,
        'description': description,
        'system_prompt': prompt,
        'can_call': tools,
        'memory_mode': _memoryMode.toJson(),
        'container_slug': _containerSlug,
      };
      if (_isTriggered) {
        // Preserve trigger fields; schedule is irrelevant
        fields['trigger_event'] = widget.agent!.triggerEvent;
        if (widget.agent!.triggerFilter != null) {
          fields['trigger_filter'] = widget.agent!.triggerFilter;
        }
      } else {
        // Only include schedule fields for scheduled Agents
        fields['schedule_enabled'] = _scheduleEnabled;
        fields['schedule_time'] = _scheduleTime;
      }
      success = await api.updateAgent(widget.agent!.name, fields);
    } else {
      // Create new agent
      final name = widget.template?.name ?? _toSlug(displayName);
      if (name.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Please enter a name'),
              backgroundColor: BrandColors.error,
            ),
          );
          setState(() => _isSaving = false);
        }
        return;
      }
      final body = <String, dynamic>{
        'name': name,
        'display_name': displayName,
        'description': description,
        'mode': 'agent',
        'system_prompt': prompt,
        'can_call': tools,
        'memory_mode': _memoryMode.toJson(),
        'container_slug': _containerSlug,
      };
      if (_isTriggered) {
        // Copy trigger fields from template
        if (widget.template != null) {
          body['trigger_event'] = widget.template!.triggerEvent;
          if (widget.template!.triggerFilter != null) {
            body['trigger_filter'] = widget.template!.triggerFilter;
          }
        }
      } else {
        // Only include schedule fields for scheduled Agents
        body['schedule_enabled'] = _scheduleEnabled;
        body['schedule_time'] = _scheduleTime;
      }
      final result = await api.createAgent(body);
      success = result != null;
    }

    if (!mounted) return;

    if (success) {
      final reloaded = await api.reloadScheduler();
      if (!reloaded) {
        debugPrint('[AgentEditScreen] reloadScheduler failed');
      }
      ref.invalidate(agentsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isEditing
                  ? '$displayName updated'
                  : '$displayName created',
            ),
            backgroundColor: BrandColors.success,
          ),
        );
        Navigator.pop(context);
      }
    } else {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isEditing ? 'Failed to update' : 'Failed to create',
          ),
          backgroundColor: BrandColors.error,
        ),
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool toggle — switch with label + description
// ─────────────────────────────────────────────────────────────────────────────

class _ToolToggle extends StatelessWidget {
  final _ToolDef tool;
  final bool enabled;
  final bool isDark;
  final ValueChanged<bool> onChanged;

  const _ToolToggle({
    required this.tool,
    required this.enabled,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.xs),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurfaceElevated
              : BrandColors.softWhite,
          borderRadius: Radii.button,
        ),
        child: Row(
          children: [
            Icon(
              tool.icon,
              size: 20,
              color: enabled
                  ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                  : BrandColors.driftwood,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                    ),
                  ),
                  Text(
                    tool.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            Semantics(
              label: tool.label,
              child: Switch.adaptive(
                value: enabled,
                onChanged: onChanged,
                activeColor: isDark
                    ? BrandColors.nightForest
                    : BrandColors.forest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Container picker — dropdown for dedicated vs named workspace
// ─────────────────────────────────────────────────────────────────────────────

class _ContainerPicker extends ConsumerWidget {
  final String selectedSlug;
  final bool isDark;
  final ValueChanged<String> onChanged;

  const _ContainerPicker({
    required this.selectedSlug,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final containersAsync = ref.watch(containersProvider);
    final color = isDark ? BrandColors.nightForest : BrandColors.forest;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: Radii.button,
      ),
      child: Row(
        children: [
          Icon(
            selectedSlug.isEmpty ? Icons.memory : Icons.workspaces_outlined,
            size: 20,
            color: color,
          ),
          SizedBox(width: Spacing.md),
          Expanded(
            child: containersAsync.when(
              data: (containers) => _buildDropdown(
                context, theme, containers, color,
              ),
              loading: () => Text(
                'Loading containers…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: BrandColors.driftwood,
                ),
              ),
              error: (_, __) => _buildDropdown(
                context, theme, <ContainerEnv>[], color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown(
    BuildContext context,
    ThemeData theme,
    List<ContainerEnv> containers,
    Color color,
  ) {
    // Build dropdown items: "Dedicated" (default) + all workspace containers
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: '',
        child: Text(
          'Dedicated (default)',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.brightness == Brightness.dark
                ? BrandColors.softWhite
                : BrandColors.ink,
          ),
        ),
      ),
      ...containers.map(
        (c) => DropdownMenuItem(
          value: c.slug,
          child: Text(
            c.displayName,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.brightness == Brightness.dark
                  ? BrandColors.softWhite
                  : BrandColors.ink,
            ),
          ),
        ),
      ),
    ];

    // If the current slug isn't in the list (e.g. non-workspace container),
    // add it so the dropdown doesn't error
    final allValues = items.map((i) => i.value).toSet();
    if (selectedSlug.isNotEmpty && !allValues.contains(selectedSlug)) {
      items.add(DropdownMenuItem(
        value: selectedSlug,
        child: Text(
          selectedSlug,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.brightness == Brightness.dark
                ? BrandColors.softWhite
                : BrandColors.ink,
          ),
        ),
      ));
    }

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selectedSlug,
        isExpanded: true,
        dropdownColor: theme.brightness == Brightness.dark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        items: items,
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Schedule config — toggle + time picker
// ─────────────────────────────────────────────────────────────────────────────

class _ScheduleConfig extends StatelessWidget {
  final bool enabled;
  final String time;
  final bool isDark;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTimeTap;

  const _ScheduleConfig({
    required this.enabled,
    required this.time,
    required this.isDark,
    required this.onToggle,
    required this.onTimeTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDark ? BrandColors.nightForest : BrandColors.forest;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated
            : BrandColors.softWhite,
        borderRadius: Radii.card,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 20,
                color: enabled ? color : BrandColors.driftwood,
              ),
              SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  'Run automatically',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                ),
              ),
              Switch.adaptive(
                value: enabled,
                onChanged: onToggle,
                activeColor: color,
              ),
            ],
          ),
          if (enabled) ...[
            Divider(
              color: isDark ? BrandColors.charcoal : BrandColors.stone,
              height: 1,
            ),
            SizedBox(height: Spacing.sm),
            InkWell(
              onTap: onTimeTap,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.xs),
                child: Row(
                  children: [
                    SizedBox(width: 32), // Align with text above
                    Text(
                      'Every day at $time',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: color,
                        decoration: TextDecoration.underline,
                        decorationColor: color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
