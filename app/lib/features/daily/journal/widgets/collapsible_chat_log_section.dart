import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_log.dart';
import 'chat_log_entry_card.dart';

/// Collapsible section showing AI conversation summaries for a day
/// Styled similarly to MorningReflectionHeader but with turquoise accent
class CollapsibleChatLogSection extends StatefulWidget {
  final ChatLog chatLog;
  final bool initiallyExpanded;

  const CollapsibleChatLogSection({
    super.key,
    required this.chatLog,
    this.initiallyExpanded = false,
  });

  @override
  State<CollapsibleChatLogSection> createState() =>
      _CollapsibleChatLogSectionState();
}

class _CollapsibleChatLogSectionState extends State<CollapsibleChatLogSection>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _controller;
  late Animation<double> _heightFactor;
  late Animation<double> _iconRotation;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _heightFactor = _controller.drive(CurveTween(curve: Curves.easeInOut));
    _iconRotation = _controller.drive(Tween(begin: 0.0, end: 0.5));

    if (_isExpanded) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (widget.chatLog.isEmpty) {
      return const SizedBox.shrink();
    }

    final entryCount = widget.chatLog.entries.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  BrandColors.nightSurfaceElevated,
                  BrandColors.nightSurface,
                ]
              : [
                  BrandColors.turquoise.withValues(alpha: 0.08),
                  BrandColors.softWhite,
                ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? BrandColors.turquoise.withValues(alpha: 0.3)
              : BrandColors.turquoise.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          // Header (always visible, tappable)
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: BrandColors.turquoise.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.forum_outlined,
                      size: 24,
                      color: BrandColors.turquoise,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI Conversations',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color:
                                isDark ? BrandColors.softWhite : BrandColors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isExpanded
                              ? 'Tap to collapse'
                              : '$entryCount session${entryCount == 1 ? '' : 's'} · Tap to view',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  RotationTransition(
                    turns: _iconRotation,
                    child: Icon(
                      Icons.expand_more,
                      color: BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expandable content
          ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _heightFactor.value,
                child: child,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(
                      color: isDark
                          ? BrandColors.charcoal.withValues(alpha: 0.5)
                          : BrandColors.stone.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 8),
                    // Chat entries - use shared card widget
                    ...widget.chatLog.entries
                        .map((entry) => ChatLogEntryCard(entry: entry, useDeepLinks: true)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
