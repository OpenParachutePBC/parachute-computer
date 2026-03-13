import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/services/computer_service.dart'
    show CallerTemplate, DailyAgentInfo;
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

const _availableTools = [
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

/// Full-screen form for creating or editing a Caller.
///
/// Pass [caller] for edit mode, or [template] for creating from a template.
/// Both null = blank creation.
class CallerEditScreen extends ConsumerStatefulWidget {
  /// Non-null when editing an existing caller.
  final DailyAgentInfo? caller;

  /// Non-null when creating from a template.
  final CallerTemplate? template;

  const CallerEditScreen({super.key, this.caller, this.template});

  bool get isEditing => caller != null;

  @override
  ConsumerState<CallerEditScreen> createState() => _CallerEditScreenState();
}

class _CallerEditScreenState extends ConsumerState<CallerEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _promptController;
  late Set<String> _enabledTools;
  late bool _scheduleEnabled;
  late String _scheduleTime;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    if (widget.isEditing) {
      // Edit mode — populate from existing caller
      final c = widget.caller!;
      _nameController = TextEditingController(text: c.displayName);
      _descriptionController = TextEditingController(text: c.description);
      _promptController = TextEditingController(text: c.systemPrompt);
      _enabledTools = Set.from(c.tools);
      _scheduleEnabled = c.scheduleEnabled;
      _scheduleTime = c.scheduleTime;
    } else if (widget.template != null) {
      // Template mode — populate from template
      final t = widget.template!;
      _nameController = TextEditingController(text: t.displayName);
      _descriptionController = TextEditingController(text: t.description);
      _promptController = TextEditingController(text: t.systemPrompt);
      _enabledTools = Set.from(t.tools);
      _scheduleEnabled = false; // Templates start unscheduled
      _scheduleTime = t.scheduleTime;
    } else {
      // Blank creation
      _nameController = TextEditingController();
      _descriptionController = TextEditingController();
      _promptController = TextEditingController();
      _enabledTools = {'read_journal', 'read_recent_journals'};
      _scheduleEnabled = false;
      _scheduleTime = '21:00';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  /// Convert display name to a slug for the caller name field.
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
    final title = widget.isEditing ? 'Edit Caller' : 'New Caller';

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
                hintText: 'What does this caller do?',
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
                hintText: 'Write the system prompt for this caller...',
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
              'Context Sources',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.xs),
            Text(
              'Choose what information this caller can access.',
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

            // ── Schedule ──────────────────────────────────────────────
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
              onToggle: (enabled) => setState(() => _scheduleEnabled = enabled),
              onTimeTap: _pickTime,
            ),

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
      // Update existing caller
      success = await api.updateCaller(widget.caller!.name, {
        'display_name': displayName,
        'description': description,
        'system_prompt': prompt,
        'tools': tools,
        'schedule_enabled': _scheduleEnabled,
        'schedule_time': _scheduleTime,
      });
    } else {
      // Create new caller
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
      final result = await api.createCaller({
        'name': name,
        'display_name': displayName,
        'description': description,
        'system_prompt': prompt,
        'tools': tools,
        'schedule_enabled': _scheduleEnabled,
        'schedule_time': _scheduleTime,
      });
      success = result != null;
    }

    if (!mounted) return;

    if (success) {
      final reloaded = await api.reloadScheduler();
      if (!reloaded) {
        debugPrint('[CallerEditScreen] reloadScheduler failed');
      }
      ref.invalidate(callersProvider);
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
