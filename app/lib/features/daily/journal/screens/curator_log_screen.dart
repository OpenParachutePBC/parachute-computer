import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/services/base_server_service.dart';
import 'package:parachute/core/providers/base_server_provider.dart';

/// Screen showing a daily agent's conversation transcript.
///
/// Design principles (matching chat app patterns):
/// - Collapse verbose context/tool results by default
/// - Highlight agent responses prominently
/// - Tool calls shown with expandable details
/// - Clean preview for collapsed content
class CuratorLogScreen extends ConsumerStatefulWidget {
  /// The agent name. If null, shows the curator log (for backwards compatibility).
  final String? agentName;

  /// Display name for the agent (used in title).
  final String? displayName;

  const CuratorLogScreen({
    super.key,
    this.agentName,
    this.displayName,
  });

  @override
  ConsumerState<CuratorLogScreen> createState() => _CuratorLogScreenState();
}

class _CuratorLogScreenState extends ConsumerState<CuratorLogScreen> {
  CuratorTranscript? _transcript;
  bool _isLoading = true;
  String? _error;

  String get _title => widget.displayName != null
      ? '${widget.displayName} Log'
      : widget.agentName != null
          ? '${_formatAgentName(widget.agentName!)} Log'
          : 'Curator Log';

  String _formatAgentName(String name) {
    return name
        .split('-')
        .map((word) => word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  @override
  void initState() {
    super.initState();
    _loadTranscript();
  }

  Future<void> _loadTranscript() async {
    debugPrint('[CuratorLogScreen] Loading transcript for agent: ${widget.agentName}');
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final service = ref.read(baseServerServiceProvider);
      final CuratorTranscript? transcript;

      if (widget.agentName != null) {
        transcript = await service.getAgentTranscript(widget.agentName!, limit: 100);
      } else {
        // Legacy path for when no agent name specified
        transcript = await service.getCuratorTranscript(limit: 100);
      }

      debugPrint('[CuratorLogScreen] Got transcript: hasTranscript=${transcript?.hasTranscript}, messages=${transcript?.messages.length}');

      setState(() {
        _transcript = transcript;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[CuratorLogScreen] Error: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadTranscript,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 16),
              Text('Error loading session log', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadTranscript,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_transcript == null || !_transcript!.hasTranscript) {
      final agentLabel = widget.displayName ?? widget.agentName ?? 'agent';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 48, color: colorScheme.outline),
              const SizedBox(height: 16),
              Text(
                'No $agentLabel history yet',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _transcript?.message ?? 'The $agentLabel hasn\'t run yet.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Header with stats
        _SessionHeader(
          transcript: _transcript!,
          agentDisplayName: widget.displayName,
          colorScheme: colorScheme,
          theme: theme,
        ),
        const SizedBox(height: 16),

        // Messages
        ..._transcript!.messages.map((msg) => _CuratorMessageBubble(
              message: msg,
              colorScheme: colorScheme,
              theme: theme,
            )),
      ],
    );
  }
}

/// Header showing session info
class _SessionHeader extends StatelessWidget {
  final CuratorTranscript transcript;
  final String? agentDisplayName;
  final ColorScheme colorScheme;
  final ThemeData theme;

  const _SessionHeader({
    required this.transcript,
    this.agentDisplayName,
    required this.colorScheme,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final sessionLabel = agentDisplayName != null
        ? '$agentDisplayName Session'
        : 'Agent Session';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(sessionLabel, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Session: ${transcript.sessionId?.substring(0, 8) ?? 'Unknown'}...',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.outline,
              ),
            ),
            Text(
              '${transcript.totalMessages} messages',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single message bubble - user messages collapsed, curator expanded
class _CuratorMessageBubble extends StatefulWidget {
  final TranscriptMessage message;
  final ColorScheme colorScheme;
  final ThemeData theme;

  const _CuratorMessageBubble({
    required this.message,
    required this.colorScheme,
    required this.theme,
  });

  @override
  State<_CuratorMessageBubble> createState() => _CuratorMessageBubbleState();
}

class _CuratorMessageBubbleState extends State<_CuratorMessageBubble> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    // Curator messages start expanded, tool results start collapsed
    _isExpanded = widget.message.isAssistant;
  }

  String _getPreview(String content) {
    if (content.isEmpty) return '';
    final firstLine = content.split('\n').first;
    if (firstLine.length > 80) {
      return '${firstLine.substring(0, 77)}...';
    }
    return firstLine;
  }

  bool _isLongContent(String? content) {
    if (content == null) return false;
    return content.length > 200 || content.split('\n').length > 3;
  }

  @override
  Widget build(BuildContext context) {
    final isAssistant = widget.message.isAssistant;
    final colorScheme = widget.colorScheme;
    final theme = widget.theme;

    final bubbleColor = isAssistant
        ? colorScheme.primaryContainer.withOpacity(0.3)
        : colorScheme.surfaceContainerHighest.withOpacity(0.5);

    final content = widget.message.content ?? '';
    final hasLongContent = _isLongContent(content);
    final showCollapsed = !isAssistant && hasLongContent && !_isExpanded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment:
            isAssistant ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          // Role label with expand/collapse
          InkWell(
            onTap: hasLongContent
                ? () => setState(() => _isExpanded = !_isExpanded)
                : null,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isAssistant ? Icons.auto_fix_high : Icons.build,
                    size: 14,
                    color: isAssistant ? colorScheme.primary : colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isAssistant ? 'Curator' : 'Tool Result',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: isAssistant ? colorScheme.primary : colorScheme.outline,
                    ),
                  ),
                  if (!isAssistant && hasLongContent) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: colorScheme.outline,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Message content
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Text content
                if (content.isNotEmpty)
                  showCollapsed
                      ? Text(
                          _getPreview(content),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.outline,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : SelectableText(
                          content,
                          style: theme.textTheme.bodyMedium,
                        ),

                // Tool blocks - always shown prominently
                if (widget.message.blocks != null)
                  ...widget.message.blocks!.map((block) => _BlockWidget(
                        block: block,
                        colorScheme: colorScheme,
                        theme: theme,
                      )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget for a single content block (text, tool_use, tool_result)
class _BlockWidget extends StatefulWidget {
  final TranscriptBlock block;
  final ColorScheme colorScheme;
  final ThemeData theme;

  const _BlockWidget({
    required this.block,
    required this.colorScheme,
    required this.theme,
  });

  @override
  State<_BlockWidget> createState() => _BlockWidgetState();
}

class _BlockWidgetState extends State<_BlockWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final theme = widget.theme;

    if (widget.block.isText && widget.block.text != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SelectableText(
          widget.block.text!,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    if (widget.block.isToolUse) {
      return _buildToolUseChip(colorScheme, theme);
    }

    if (widget.block.isToolResult) {
      return _buildToolResultChip(colorScheme, theme);
    }

    return const SizedBox.shrink();
  }

  Widget _buildToolUseChip(ColorScheme colorScheme, ThemeData theme) {
    final toolColor = colorScheme.tertiary;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: toolColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: toolColor.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow, size: 14, color: toolColor),
                  const SizedBox(width: 4),
                  Text(
                    widget.block.name ?? 'Tool',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: toolColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: toolColor,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && widget.block.input != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                widget.block.input!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolResultChip(ColorScheme colorScheme, ThemeData theme) {
    final hasContent = widget.block.text != null && widget.block.text!.isNotEmpty;
    if (!hasContent) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.outline.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.output, size: 14, color: colorScheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    'Result',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.block.text!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
