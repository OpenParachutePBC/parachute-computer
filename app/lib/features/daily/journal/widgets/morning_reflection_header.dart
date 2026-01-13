import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/reflection.dart';
import '../screens/curator_log_screen.dart';

/// Expandable header showing the morning reflection for a day
class MorningReflectionHeader extends StatefulWidget {
  final Reflection reflection;
  final bool initiallyExpanded;

  const MorningReflectionHeader({
    super.key,
    required this.reflection,
    this.initiallyExpanded = false,
  });

  @override
  State<MorningReflectionHeader> createState() => _MorningReflectionHeaderState();
}

class _MorningReflectionHeaderState extends State<MorningReflectionHeader>
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
                  BrandColors.forestMist,
                  BrandColors.softWhite,
                ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? BrandColors.forest.withValues(alpha: 0.3)
              : BrandColors.forest.withValues(alpha: 0.2),
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
                      color: BrandColors.forest.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.wb_twilight,
                      size: 24,
                      color: BrandColors.forest,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Morning Reflection',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: isDark ? BrandColors.softWhite : BrandColors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isExpanded ? 'Tap to collapse' : 'Tap to read',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // View log button
                  IconButton(
                    icon: Icon(
                      Icons.history,
                      size: 20,
                      color: BrandColors.driftwood,
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const CuratorLogScreen(),
                        ),
                      );
                    },
                    tooltip: 'View curator log',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
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
                    MarkdownBody(
                      data: widget.reflection.content,
                      selectable: true,
                      onTapLink: (text, href, title) {
                        if (href != null) {
                          launchUrl(Uri.parse(href));
                        }
                      },
                      styleSheet: MarkdownStyleSheet(
                        p: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          height: 1.6,
                        ),
                        h1: theme.textTheme.titleLarge?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        h2: theme.textTheme.titleMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        h3: theme.textTheme.titleSmall?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        blockquote: theme.textTheme.bodyMedium?.copyWith(
                          color: BrandColors.driftwood,
                          fontStyle: FontStyle.italic,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: BrandColors.forest.withValues(alpha: 0.5),
                              width: 3,
                            ),
                          ),
                        ),
                        code: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          backgroundColor: isDark
                              ? BrandColors.charcoal.withValues(alpha: 0.5)
                              : BrandColors.stone.withValues(alpha: 0.3),
                        ),
                        a: theme.textTheme.bodyMedium?.copyWith(
                          color: BrandColors.turquoise,
                          decoration: TextDecoration.underline,
                        ),
                        listBullet: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                        ),
                        strong: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        em: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
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

/// Compact preview card for when reflection exists but user hasn't engaged
class MorningReflectionPreview extends StatelessWidget {
  final Reflection reflection;
  final VoidCallback onTap;

  const MorningReflectionPreview({
    super.key,
    required this.reflection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Get first sentence or first 100 chars
    final preview = _getPreview(reflection.content);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    BrandColors.forest.withValues(alpha: 0.15),
                    BrandColors.nightSurfaceElevated,
                  ]
                : [
                    BrandColors.forestMist,
                    BrandColors.softWhite,
                  ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: BrandColors.forest.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.wb_twilight,
              size: 20,
              color: BrandColors.forest,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                preview,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: BrandColors.driftwood,
            ),
          ],
        ),
      ),
    );
  }

  String _getPreview(String content) {
    // Try to get first sentence
    final sentenceEnd = content.indexOf('. ');
    if (sentenceEnd > 0 && sentenceEnd < 150) {
      return content.substring(0, sentenceEnd + 1);
    }
    // Otherwise first 100 chars
    if (content.length > 100) {
      return '${content.substring(0, 100)}...';
    }
    return content;
  }
}
