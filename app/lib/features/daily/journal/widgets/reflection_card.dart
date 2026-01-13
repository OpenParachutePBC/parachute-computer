import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/reflection.dart';

/// Displays a daily reflection in a gentle, collapsible card.
///
/// The reflection is shown at the top of the journal screen when
/// one exists for that day. It can be expanded/collapsed.
class ReflectionCard extends StatefulWidget {
  final Reflection reflection;
  final bool initiallyExpanded;

  const ReflectionCard({
    super.key,
    required this.reflection,
    this.initiallyExpanded = false,
  });

  @override
  State<ReflectionCard> createState() => _ReflectionCardState();
}

class _ReflectionCardState extends State<ReflectionCard>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _controller;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    if (_isExpanded) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
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

    // Gentle gradient background - like a soft glow
    final backgroundColor = isDark
        ? BrandColors.nightSurface
        : BrandColors.turquoiseMist.withValues(alpha: 0.3);

    final borderColor = isDark
        ? BrandColors.turquoiseDeep.withValues(alpha: 0.3)
        : BrandColors.turquoise.withValues(alpha: 0.2);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header - always visible
          InkWell(
            onTap: _toggleExpanded,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Icon
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? BrandColors.turquoiseDeep.withValues(alpha: 0.2)
                          : BrandColors.turquoise.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      size: 18,
                      color: isDark
                          ? BrandColors.turquoiseLight
                          : BrandColors.turquoiseDeep,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Title
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Daily Reflection',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: isDark
                                ? BrandColors.turquoiseLight
                                : BrandColors.turquoiseDeep,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (!_isExpanded) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.reflection.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? BrandColors.driftwood
                                  : BrandColors.charcoal.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Expand/collapse icon
                  AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: isDark
                          ? BrandColors.driftwood
                          : BrandColors.charcoal.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Content - expandable
          SizeTransition(
            sizeFactor: _expandAnimation,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  // Reflection content
                  Text(
                    widget.reflection.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? BrandColors.stone : BrandColors.charcoal,
                      height: 1.6,
                    ),
                  ),
                  // Generated timestamp
                  if (widget.reflection.generatedAt != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _formatGeneratedAt(widget.reflection.generatedAt!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? BrandColors.driftwood.withValues(alpha: 0.7)
                            : BrandColors.driftwood,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatGeneratedAt(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) {
      return 'Generated just now';
    } else if (diff.inHours < 1) {
      return 'Generated ${diff.inMinutes} minutes ago';
    } else if (diff.inDays < 1) {
      return 'Generated ${diff.inHours} hours ago';
    } else {
      return 'Generated ${dt.month}/${dt.day} at ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
  }
}
