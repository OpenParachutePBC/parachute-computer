import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/services/computer_service.dart'
    show DailyAgentInfo;
import '../providers/journal_providers.dart';
import '../utils/agent_theme.dart';
import '../utils/time_helpers.dart';

/// Bottom sheet showing Caller details with schedule config and actions.
class CallerDetailSheet extends ConsumerStatefulWidget {
  final DailyAgentInfo caller;

  /// Called when the user taps "View history". The sheet pops itself first,
  /// then invokes this callback so navigation uses the parent's context.
  final VoidCallback? onViewHistory;

  /// Called when the user taps "Edit". The sheet pops itself first,
  /// then invokes this callback so navigation uses the parent's context.
  final VoidCallback? onEdit;

  const CallerDetailSheet({
    super.key,
    required this.caller,
    this.onViewHistory,
    this.onEdit,
  });

  @override
  ConsumerState<CallerDetailSheet> createState() => _CallerDetailSheetState();
}

class _CallerDetailSheetState extends ConsumerState<CallerDetailSheet> {
  late bool _scheduleEnabled;
  late String _scheduleTime;
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _scheduleEnabled = widget.caller.scheduleEnabled;
    _scheduleTime = widget.caller.scheduleTime;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final agentTheme = AgentTheme.forAgent(widget.caller.name);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.xl),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: EdgeInsets.only(top: Spacing.md),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? BrandColors.charcoal : BrandColors.stone,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  Spacing.xl,
                  Spacing.lg,
                  Spacing.xl,
                  Spacing.xl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: icon + name
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: agentTheme.color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(Radii.md),
                          ),
                          child: Icon(
                            agentTheme.icon,
                            size: 28,
                            color: agentTheme.color,
                          ),
                        ),
                        SizedBox(width: Spacing.lg),
                        Expanded(
                          child: Text(
                            widget.caller.displayName,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? BrandColors.softWhite
                                  : BrandColors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),

                    // Description
                    if (widget.caller.description.isNotEmpty) ...[
                      SizedBox(height: Spacing.lg),
                      Text(
                        widget.caller.description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark
                              ? BrandColors.stone
                              : BrandColors.charcoal,
                          height: 1.5,
                        ),
                      ),
                    ],

                    // Trigger / Schedule section
                    SizedBox(height: Spacing.xl),
                    if (widget.caller.isTriggered) ...[
                      Text(
                        'Trigger',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      SizedBox(height: Spacing.sm),
                      _TriggerInfo(
                        triggerEvent: widget.caller.triggerEvent,
                        triggerFilter: widget.caller.triggerFilter,
                        isDark: isDark,
                        agentColor: agentTheme.color,
                      ),
                    ] else ...[
                      Text(
                        'Schedule',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? BrandColors.softWhite
                              : BrandColors.ink,
                        ),
                      ),
                      SizedBox(height: Spacing.sm),
                      _ScheduleRow(
                        enabled: _scheduleEnabled,
                        time: _scheduleTime,
                        isDark: isDark,
                        agentColor: agentTheme.color,
                        callerName: widget.caller.displayName,
                        onToggle: _toggleSchedule,
                        onTimeTap: _pickTime,
                      ),
                    ],

                    // Actions
                    SizedBox(height: Spacing.xl),
                    Text(
                      'Actions',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      ),
                    ),
                    SizedBox(height: Spacing.sm),
                    _ActionButton(
                      icon: Icons.edit_outlined,
                      label: 'Edit caller',
                      color: isDark
                          ? BrandColors.nightTurquoise
                          : BrandColors.turquoise,
                      isDark: isDark,
                      showChevron: true,
                      onTap: () => _editCaller(context),
                    ),
                    // Only show "Run now" for scheduled (day-scoped) Callers.
                    // Triggered Callers run automatically on events — they need
                    // a specific entry to operate on, so "Run now" doesn't apply.
                    if (!widget.caller.isTriggered) ...[
                      SizedBox(height: Spacing.sm),
                      _ActionButton(
                        icon: Icons.play_arrow,
                        label: _isRunning ? 'Running...' : 'Run now',
                        color: isDark
                            ? BrandColors.nightForest
                            : BrandColors.forest,
                        isDark: isDark,
                        enabled: !_isRunning,
                        onTap: _runNow,
                      ),
                    ],
                    SizedBox(height: Spacing.sm),
                    _ActionButton(
                      icon: Icons.history,
                      label: 'View history',
                      color: isDark
                          ? BrandColors.nightTurquoise
                          : BrandColors.turquoise,
                      isDark: isDark,
                      showChevron: true,
                      onTap: () => _viewHistory(context),
                    ),
                    SizedBox(height: Spacing.sm),
                    _ActionButton(
                      icon: Icons.restart_alt,
                      label: 'Reset session',
                      color: BrandColors.warning,
                      isDark: isDark,
                      onTap: () => _resetCaller(context),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSchedule(bool enabled) async {
    setState(() => _scheduleEnabled = enabled);
    final api = ref.read(dailyApiServiceProvider);
    final success = await api.updateCaller(widget.caller.name, {
      'schedule_enabled': enabled,
    });
    if (!mounted) return;
    if (success) {
      await api.reloadScheduler();
      if (mounted) ref.invalidate(callersProvider);
    } else {
      // Revert on failure
      setState(() => _scheduleEnabled = !enabled);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: parseHHMM(
        _scheduleTime,
        fallback: const TimeOfDay(hour: 3, minute: 0),
      ),
    );
    if (picked == null || !mounted) return;

    final newTime = formatTimeOfDay(picked);
    setState(() => _scheduleTime = newTime);

    final api = ref.read(dailyApiServiceProvider);
    final success = await api.updateCaller(widget.caller.name, {
      'schedule_time': newTime,
    });
    if (!mounted) return;
    if (success) {
      await api.reloadScheduler();
      if (mounted) ref.invalidate(callersProvider);
    }
  }

  Future<void> _runNow() async {
    setState(() => _isRunning = true);
    final api = ref.read(dailyApiServiceProvider);
    try {
      await api.triggerAgentRun(widget.caller.name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.caller.displayName} started'),
            backgroundColor: BrandColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to run: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
        ref.read(journalRefreshTriggerProvider.notifier).state++;
      }
    }
  }

  void _viewHistory(BuildContext context) {
    Navigator.pop(context); // Close sheet first
    widget.onViewHistory?.call();
  }

  void _editCaller(BuildContext context) {
    Navigator.pop(context); // Close sheet first
    widget.onEdit?.call();
  }

  Future<void> _resetCaller(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset ${widget.caller.displayName}?'),
        content: const Text(
          'This clears the agent\'s conversation history. '
          'The next run will start fresh without previous context.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = ref.read(dailyApiServiceProvider);
    final success = await api.resetCaller(widget.caller.name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '${widget.caller.displayName} reset — next run starts fresh'
                : 'Failed to reset',
          ),
          backgroundColor: success ? BrandColors.success : BrandColors.error,
        ),
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Schedule row — toggle + time picker
// ─────────────────────────────────────────────────────────────────────────────

class _ScheduleRow extends StatelessWidget {
  final bool enabled;
  final String time;
  final bool isDark;
  final Color agentColor;
  final String callerName;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTimeTap;

  const _ScheduleRow({
    required this.enabled,
    required this.time,
    required this.isDark,
    required this.agentColor,
    required this.callerName,
    required this.onToggle,
    required this.onTimeTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          Icon(
            Icons.schedule,
            size: 20,
            color: enabled ? agentColor : BrandColors.driftwood,
          ),
          SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Run automatically',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                ),
                if (enabled)
                  InkWell(
                    onTap: onTimeTap,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 2,
                      ),
                      child: Text(
                        'Every day at $time',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: agentColor,
                          decoration: TextDecoration.underline,
                          decorationColor: agentColor,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Semantics(
            label: 'Schedule ${callerName}',
            child: Switch.adaptive(
              value: enabled,
              onChanged: onToggle,
              activeColor: isDark
                  ? BrandColors.nightForest
                  : BrandColors.forest,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trigger info — shows event name and filter for event-driven Callers
// ─────────────────────────────────────────────────────────────────────────────

class _TriggerInfo extends StatelessWidget {
  final String triggerEvent;
  final Map<String, dynamic>? triggerFilter;
  final bool isDark;
  final Color agentColor;

  const _TriggerInfo({
    required this.triggerEvent,
    this.triggerFilter,
    required this.isDark,
    required this.agentColor,
  });

  /// Human-readable label for a trigger event name.
  String _eventLabel(String event) {
    switch (event) {
      case 'note.transcription_complete':
        return 'When transcription completes';
      case 'note.created':
        return 'When a new note is created';
      default:
        return event;
    }
  }

  /// Human-readable label for a trigger filter.
  String? _filterLabel(Map<String, dynamic>? filter) {
    if (filter == null || filter.isEmpty) return null;
    final parts = <String>[];
    if (filter.containsKey('entry_type')) {
      parts.add('type: ${filter['entry_type']}');
    }
    if (filter.containsKey('tags')) {
      final tags = filter['tags'];
      if (tags is List) {
        parts.add('tags: ${tags.join(', ')}');
      }
    }
    return parts.isEmpty ? null : parts.join(' \u2022 ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filterLabel = _filterLabel(triggerFilter);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.md,
      ),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
        borderRadius: Radii.card,
      ),
      child: Row(
        children: [
          Icon(
            Icons.bolt,
            size: 20,
            color: agentColor,
          ),
          SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _eventLabel(triggerEvent),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                ),
                if (filterLabel != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    filterLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: BrandColors.driftwood,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Action button — row with icon + label
// ─────────────────────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool isDark;
  final bool enabled;
  final bool showChevron;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.isDark,
    this.enabled = true,
    this.showChevron = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: Radii.button,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.md,
          ),
          decoration: BoxDecoration(
            color: isDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.cream,
            borderRadius: Radii.button,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: enabled ? color : BrandColors.driftwood,
              ),
              SizedBox(width: Spacing.md),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: enabled
                      ? (isDark ? BrandColors.softWhite : BrandColors.ink)
                      : BrandColors.driftwood,
                ),
              ),
              if (showChevron) ...[
                const Spacer(),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: BrandColors.driftwood,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
