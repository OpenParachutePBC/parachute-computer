import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_message.dart';

/// Inline section showing the agent's thinking process and tool calls
///
/// Thinking text is shown expanded by default.
/// Tool calls are shown as compact chips, expandable for full input details.
class CollapsibleThinkingSection extends StatefulWidget {
  /// Content items in order (thinking text and tool calls interleaved)
  final List<MessageContent> items;
  final bool isDark;

  /// Whether the section should start expanded (true during streaming)
  final bool initiallyExpanded;

  const CollapsibleThinkingSection({
    super.key,
    required this.items,
    required this.isDark,
    this.initiallyExpanded = false,
  });

  @override
  State<CollapsibleThinkingSection> createState() => _CollapsibleThinkingSectionState();
}

class _CollapsibleThinkingSectionState extends State<CollapsibleThinkingSection> {
  final Set<int> _expandedTools = {};
  late bool _sectionExpanded;

  @override
  void initState() {
    super.initState();
    _sectionExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    // Count tools and thinking blocks for summary
    final toolCount = widget.items.where((i) => i.type == ContentType.toolUse).length;
    final thinkingCount = widget.items.where((i) => i.type == ContentType.thinking).length;

    return Padding(
      padding: const EdgeInsets.only(
        left: Spacing.md,
        right: Spacing.md,
        bottom: Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsible header for the whole section
          GestureDetector(
            onTap: () => setState(() => _sectionExpanded = !_sectionExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? BrandColors.nightSurface.withValues(alpha: 0.3)
                    : BrandColors.cream.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _sectionExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: widget.isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: widget.isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    _buildSummaryText(toolCount, thinkingCount),
                    style: TextStyle(
                      color: widget.isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                      fontSize: TypographyTokens.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Expanded content
          if (_sectionExpanded) ...[
            const SizedBox(height: Spacing.sm),
            ...widget.items.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;

              if (item.type == ContentType.thinking) {
                return _buildThinkingBlock(item.text ?? '');
              } else if (item.type == ContentType.toolUse && item.toolCall != null) {
                return _buildToolCall(index, item.toolCall!);
              }
              return const SizedBox.shrink();
            }),
          ],
        ],
      ),
    );
  }

  String _buildSummaryText(int toolCount, int thinkingCount) {
    final parts = <String>[];
    if (toolCount > 0) {
      parts.add('$toolCount tool${toolCount > 1 ? 's' : ''}');
    }
    if (thinkingCount > 0) {
      parts.add('$thinkingCount thought${thinkingCount > 1 ? 's' : ''}');
    }
    return parts.isEmpty ? 'Thinking...' : parts.join(', ');
  }

  /// Thinking block - shown expanded as muted text
  Widget _buildThinkingBlock(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: widget.isDark
            ? BrandColors.nightSurface.withValues(alpha: 0.3)
            : BrandColors.cream.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: widget.isDark
              ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
              : BrandColors.driftwood.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: Spacing.xs),
            child: Icon(
              Icons.psychology_outlined,
              size: 14,
              color: widget.isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.6)
                  : BrandColors.driftwood.withValues(alpha: 0.6),
            ),
          ),
          Expanded(
            // Render thinking text as plain text to avoid flutter_markdown crashes
            // Thinking blocks often contain XML-like tags that break the parser
            child: Text(
              text,
              style: TextStyle(
                color: widget.isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.charcoal.withValues(alpha: 0.7),
                fontSize: TypographyTokens.bodySmall,
                height: TypographyTokens.lineHeightNormal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Tool call - compact chip, expandable for full input and result
  Widget _buildToolCall(int index, ToolCall toolCall) {
    final isExpanded = _expandedTools.contains(index);
    final hasInput = toolCall.input.isNotEmpty;
    final hasResult = toolCall.result != null;
    final hasDetails = hasInput || hasResult;

    // Chip color - error results get error styling
    final chipColor = toolCall.isError
        ? (widget.isDark ? BrandColors.error : BrandColors.error)
        : (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise);

    // Special rendering for specific tools
    if (toolCall.name.toLowerCase() == 'todowrite' && !isExpanded) {
      return _buildTodoWriteCard(index, toolCall, chipColor, hasDetails);
    }
    if (toolCall.name.toLowerCase() == 'task' && !isExpanded) {
      return _buildTaskAgentCard(index, toolCall, chipColor, hasDetails);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact chip header
          GestureDetector(
            onTap: hasDetails ? () => _toggleTool(index) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: chipColor.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    toolCall.isError ? Icons.error_outline : _getToolIcon(toolCall.name),
                    size: 12,
                    color: chipColor,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    _formatToolName(toolCall.name),
                    style: TextStyle(
                      color: toolCall.isError
                          ? chipColor
                          : (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep),
                      fontSize: TypographyTokens.labelSmall,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (toolCall.summary.isNotEmpty && !isExpanded) ...[
                    const SizedBox(width: Spacing.xs),
                    Flexible(
                      child: Text(
                        toolCall.summary,
                        style: TextStyle(
                          color: widget.isDark
                              ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                              : BrandColors.driftwood.withValues(alpha: 0.7),
                          fontSize: TypographyTokens.labelSmall,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  // Show checkmark if result received (success)
                  if (hasResult && !toolCall.isError && !isExpanded) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      Icons.check_circle_outline,
                      size: 12,
                      color: widget.isDark
                          ? BrandColors.nightForest
                          : BrandColors.forest,
                    ),
                  ],
                  if (hasDetails) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: chipColor.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Expanded details (input and result)
          if (isExpanded && hasDetails)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.softWhite,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: widget.isDark
                      ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                      : BrandColors.driftwood.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Input section
                  if (hasInput) ...[
                    Text(
                      'Input',
                      style: TextStyle(
                        color: widget.isDark
                            ? BrandColors.nightTextSecondary.withValues(alpha: 0.6)
                            : BrandColors.driftwood.withValues(alpha: 0.6),
                        fontSize: TypographyTokens.labelSmall - 1,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    SelectableText(
                      _formatInput(toolCall.input),
                      style: TextStyle(
                        color: widget.isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                        fontSize: TypographyTokens.labelSmall,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ],
                  // Result section
                  if (hasResult) ...[
                    if (hasInput) const SizedBox(height: Spacing.sm),
                    Row(
                      children: [
                        Text(
                          toolCall.isError ? 'Error' : 'Result',
                          style: TextStyle(
                            color: toolCall.isError
                                ? BrandColors.error
                                : (widget.isDark
                                    ? BrandColors.nightForest
                                    : BrandColors.forest),
                            fontSize: TypographyTokens.labelSmall - 1,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Icon(
                          toolCall.isError ? Icons.error_outline : Icons.check_circle_outline,
                          size: 12,
                          color: toolCall.isError
                              ? BrandColors.error
                              : (widget.isDark
                                  ? BrandColors.nightForest
                                  : BrandColors.forest),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.xs),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _formatResult(toolCall.result!),
                          style: TextStyle(
                            color: toolCall.isError
                                ? BrandColors.error.withValues(alpha: 0.9)
                                : (widget.isDark
                                    ? BrandColors.nightText
                                    : BrandColors.charcoal),
                            fontSize: TypographyTokens.labelSmall,
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
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

  /// Special card for TodoWrite tool - shows todos inline
  Widget _buildTodoWriteCard(int index, ToolCall toolCall, Color chipColor, bool hasDetails) {
    final todos = toolCall.input['todos'] as List<dynamic>? ?? [];

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with expand button
          GestureDetector(
            onTap: hasDetails ? () => _toggleTool(index) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: chipColor.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.checklist,
                    size: 12,
                    color: chipColor,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'TodoWrite',
                    style: TextStyle(
                      color: widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep,
                      fontSize: TypographyTokens.labelSmall,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    '${todos.length} item${todos.length != 1 ? 's' : ''}',
                    style: TextStyle(
                      color: widget.isDark
                          ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                          : BrandColors.driftwood.withValues(alpha: 0.7),
                      fontSize: TypographyTokens.labelSmall,
                    ),
                  ),
                  if (hasDetails) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      Icons.expand_more,
                      size: 14,
                      color: chipColor.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Inline todo list (collapsed view)
          if (todos.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < todos.length && i < 5; i++)
                    _buildTodoItem(todos[i] as Map<String, dynamic>),
                  if (todos.length > 5)
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.xs),
                      child: Text(
                        '... and ${todos.length - 5} more',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: widget.isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTodoItem(Map<String, dynamic> todo) {
    final status = todo['status'] as String? ?? 'pending';
    final content = todo['content'] as String? ?? '';
    final activeForm = todo['activeForm'] as String?;

    final IconData icon;
    final Color iconColor;
    final bool isActive = status == 'in_progress';

    switch (status) {
      case 'completed':
        icon = Icons.check_circle;
        iconColor = widget.isDark ? BrandColors.nightForest : BrandColors.forest;
        break;
      case 'in_progress':
        icon = Icons.play_circle;
        iconColor = widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
        break;
      default:
        icon = Icons.circle_outlined;
        iconColor = widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              isActive ? (activeForm ?? content) : content,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: status == 'completed'
                    ? (widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                    : (widget.isDark ? BrandColors.nightText : BrandColors.charcoal),
                decoration: status == 'completed' ? TextDecoration.lineThrough : null,
                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Special card for Task tool (agent) - shows description and status
  Widget _buildTaskAgentCard(int index, ToolCall toolCall, Color chipColor, bool hasDetails) {
    final description = toolCall.input['description'] as String? ?? '';
    final subagentType = toolCall.input['subagent_type'] as String? ?? 'general';
    final hasResult = toolCall.result != null;

    // Determine agent icon based on type
    IconData agentIcon;
    switch (subagentType.toLowerCase()) {
      case 'bash':
        agentIcon = Icons.terminal;
        break;
      case 'explore':
        agentIcon = Icons.explore;
        break;
      case 'plan':
        agentIcon = Icons.architecture;
        break;
      case 'code-reviewer':
        agentIcon = Icons.rate_review;
        break;
      case 'creative-director':
        agentIcon = Icons.palette;
        break;
      default:
        agentIcon = Icons.smart_toy;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with expand button
          GestureDetector(
            onTap: hasDetails ? () => _toggleTool(index) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: chipColor.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    agentIcon,
                    size: 12,
                    color: chipColor,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'Task',
                    style: TextStyle(
                      color: widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep,
                      fontSize: TypographyTokens.labelSmall,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: widget.isDark
                          ? BrandColors.nightSurface
                          : BrandColors.cream,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      subagentType,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall - 1,
                        color: widget.isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  if (hasResult && !toolCall.isError) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      Icons.check_circle_outline,
                      size: 12,
                      color: widget.isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                  ],
                  if (hasDetails) ...[
                    const SizedBox(width: Spacing.xs),
                    Icon(
                      Icons.expand_more,
                      size: 14,
                      color: chipColor.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Task description preview
          if (description.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: Spacing.xs, left: Spacing.sm),
              padding: const EdgeInsets.all(Spacing.xs),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? BrandColors.nightSurface.withValues(alpha: 0.3)
                    : BrandColors.cream.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.short_text,
                    size: 12,
                    color: widget.isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      description,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: widget.isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _toggleTool(int index) {
    setState(() {
      if (_expandedTools.contains(index)) {
        _expandedTools.remove(index);
      } else {
        _expandedTools.add(index);
      }
    });
  }

  String _formatToolName(String name) {
    if (name.startsWith('mcp__')) {
      final parts = name.split('__');
      if (parts.length >= 3) {
        return '${parts[1]}/${parts[2]}';
      }
    }
    return name;
  }

  String _formatInput(Map<String, dynamic> input) {
    final buffer = StringBuffer();
    for (final entry in input.entries) {
      final value = entry.value;
      String displayValue;

      if (value is String) {
        // Show more of the value when expanded
        if (value.length > 500) {
          displayValue = '${value.substring(0, 497)}...';
        } else {
          displayValue = value;
        }
        buffer.writeln('${entry.key}: $displayValue');
      } else if (value is List) {
        // Format lists nicely (especially for TodoWrite)
        buffer.writeln('${entry.key}:');
        for (var i = 0; i < value.length && i < 10; i++) {
          final item = value[i];
          if (item is Map) {
            // Format todo items nicely
            final status = item['status'] ?? '';
            final content = item['content'] ?? item.toString();
            final icon = status == 'completed' ? '✓' : status == 'in_progress' ? '→' : '○';
            buffer.writeln('  $icon $content');
          } else {
            buffer.writeln('  • $item');
          }
        }
        if (value.length > 10) {
          buffer.writeln('  ... and ${value.length - 10} more');
        }
      } else if (value is Map) {
        // Format JSON-like structures
        displayValue = value.toString();
        if (displayValue.length > 200) {
          displayValue = '${displayValue.substring(0, 197)}...';
        }
        buffer.writeln('${entry.key}: $displayValue');
      } else {
        displayValue = value.toString();
        buffer.writeln('${entry.key}: $displayValue');
      }
    }
    return buffer.toString().trimRight();
  }

  String _formatResult(String result) {
    // Truncate very long results
    if (result.length > 2000) {
      return '${result.substring(0, 1997)}...';
    }
    return result;
  }

  IconData _getToolIcon(String toolName) {
    final name = toolName.toLowerCase();
    if (name == 'skill') return Icons.auto_awesome;
    if (name == 'todowrite') return Icons.checklist;
    if (name == 'task') return Icons.account_tree;
    if (name.contains('read')) return Icons.description_outlined;
    if (name.contains('bash')) return Icons.terminal;
    if (name.contains('glob') || name.contains('grep')) return Icons.search;
    if (name.contains('write') || name.contains('edit')) return Icons.edit_outlined;
    if (name.contains('search')) return Icons.search;
    if (name.contains('image') || name.contains('generate')) return Icons.image_outlined;
    if (name.contains('browser') || name.contains('navigate')) return Icons.public;
    if (name.contains('click')) return Icons.mouse;
    if (name.contains('snapshot')) return Icons.camera_alt_outlined;
    if (name.contains('glif')) return Icons.brush;
    return Icons.build_outlined;
  }
}
