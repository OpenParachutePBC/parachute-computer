import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:parachute/core/theme/design_tokens.dart';

/// Threshold for auto-collapsing code blocks (in lines)
const int _collapseThreshold = 15;

/// Number of preview lines to show when collapsed
const int _previewLines = 8;

/// Custom code block builder that auto-collapses large code blocks
class CollapsibleCodeBlockBuilder extends MarkdownElementBuilder {
  final bool isDark;

  CollapsibleCodeBlockBuilder({required this.isDark});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // Only handle code blocks (pre > code), not inline code
    if (element.tag != 'pre') return null;

    // Get the code content
    String codeContent = element.textContent;

    // Count lines
    final lines = codeContent.split('\n');
    final lineCount = lines.length;

    // For large blocks, use our collapsible widget
    if (lineCount > _collapseThreshold) {
      return CollapsibleCodeBlock(
        code: codeContent,
        lineCount: lineCount,
        isDark: isDark,
      );
    }

    // For smaller blocks, render a simple styled code block
    // (returning null doesn't properly fall back to default rendering)
    final bgColor = isDark ? BrandColors.nightSurface : BrandColors.cream;
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: SelectableText(
        codeContent,
        style: TextStyle(
          color: textColor,
          fontFamily: 'monospace',
          fontSize: TypographyTokens.bodySmall,
          height: 1.4,
        ),
      ),
    );
  }
}

/// A collapsible code block widget for large code content
class CollapsibleCodeBlock extends StatefulWidget {
  final String code;
  final int lineCount;
  final bool isDark;

  const CollapsibleCodeBlock({
    super.key,
    required this.code,
    required this.lineCount,
    required this.isDark,
  });

  @override
  State<CollapsibleCodeBlock> createState() => _CollapsibleCodeBlockState();
}

class _CollapsibleCodeBlockState extends State<CollapsibleCodeBlock> {
  bool _isExpanded = false;

  String get _previewText {
    final lines = widget.code.split('\n');
    if (lines.length <= _previewLines) return widget.code;
    return lines.take(_previewLines).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final bgColor =
        widget.isDark ? BrandColors.nightSurface : BrandColors.cream;
    final textColor =
        widget.isDark ? BrandColors.nightText : BrandColors.charcoal;
    final secondaryColor =
        widget.isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final accentColor =
        widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.xs),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: secondaryColor.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with line count and expand/collapse button
          GestureDetector(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
                vertical: Spacing.xs,
              ),
              decoration: BoxDecoration(
                color: secondaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(Radii.sm),
                  bottom: _isExpanded ? Radius.zero : const Radius.circular(Radii.sm),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.code,
                    size: 14,
                    color: accentColor,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    '${widget.lineCount} lines',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: secondaryColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _isExpanded ? 'Collapse' : 'Expand',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: accentColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: accentColor,
                  ),
                ],
              ),
            ),
          ),

          // Code content
          if (_isExpanded)
            // Full content with max height and scroll
            Container(
              constraints: const BoxConstraints(maxHeight: 400),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Spacing.sm),
                child: SelectableText(
                  widget.code,
                  style: TextStyle(
                    color: textColor,
                    fontFamily: 'monospace',
                    fontSize: TypographyTokens.bodySmall,
                    height: 1.4,
                  ),
                ),
              ),
            )
          else
            // Preview with fade
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Text(
                    _previewText,
                    style: TextStyle(
                      color: textColor,
                      fontFamily: 'monospace',
                      fontSize: TypographyTokens.bodySmall,
                      height: 1.4,
                    ),
                    maxLines: _previewLines,
                    overflow: TextOverflow.clip,
                  ),
                ),
                // Fade gradient at bottom
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          bgColor.withValues(alpha: 0),
                          bgColor,
                        ],
                      ),
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(Radii.sm),
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
