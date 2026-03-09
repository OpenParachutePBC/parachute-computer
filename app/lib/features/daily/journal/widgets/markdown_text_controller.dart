import 'package:flutter/material.dart';

/// A [TextEditingController] that applies lightweight inline markdown styling
/// while keeping all syntax characters visible.
///
/// Only styles inline patterns (bold, italic, code) — these are safe and
/// well-tested with Flutter's RenderEditable. Block-level patterns (headings,
/// quotes, lists) are deliberately left unstyled in source view; use the
/// preview toggle to see them rendered.
///
/// The entire [buildTextSpan] is wrapped in try-catch so that any regex or
/// indexing edge case degrades to plain text instead of crashing the editor.
class MarkdownTextEditingController extends TextEditingController {
  final Color syntaxColor;
  final Color bodyColor;

  MarkdownTextEditingController({
    super.text,
    required this.syntaxColor,
    required this.bodyColor,
  });

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    if (text.isEmpty) {
      return TextSpan(text: text, style: style);
    }

    try {
      final children = <InlineSpan>[];
      _applyInlinePatterns(text, style, children);
      if (children.isEmpty) {
        return TextSpan(text: text, style: style);
      }
      return TextSpan(style: style, children: children);
    } catch (_) {
      // Any failure → plain text. Never crash the editor.
      return TextSpan(text: text, style: style);
    }
  }

  /// Find all bold, italic, and code spans in [text] and emit styled
  /// [TextSpan]s into [out]. Unmatched regions become plain text spans.
  void _applyInlinePatterns(
      String text, TextStyle? baseStyle, List<InlineSpan> out) {
    final matches = <_InlineMatch>[];

    for (final match in _boldRegex.allMatches(text)) {
      matches.add(_InlineMatch(match.start, match.end, 'bold', match));
    }
    for (final match in _italicRegex.allMatches(text)) {
      // Skip if overlaps with any existing match (standard interval overlap)
      final overlaps = matches.any((m) =>
          match.start < m.end && match.end > m.start);
      if (!overlaps) {
        matches.add(_InlineMatch(match.start, match.end, 'italic', match));
      }
    }
    for (final match in _codeRegex.allMatches(text)) {
      // Skip if overlaps with any existing match
      final overlaps = matches.any((m) =>
          match.start < m.end && match.end > m.start);
      if (!overlaps) {
        matches.add(_InlineMatch(match.start, match.end, 'code', match));
      }
    }

    if (matches.isEmpty) {
      out.add(TextSpan(text: text, style: baseStyle));
      return;
    }

    // Sort by position
    matches.sort((a, b) => a.start.compareTo(b.start));

    // Remove overlapping matches (keep earlier ones)
    final filtered = <_InlineMatch>[];
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start >= lastEnd) {
        filtered.add(m);
        lastEnd = m.end;
      }
    }

    // Build spans
    var cursor = 0;
    for (final m in filtered) {
      // Plain text before this match
      if (m.start > cursor) {
        out.add(TextSpan(
          text: text.substring(cursor, m.start),
          style: baseStyle,
        ));
      }

      final match = m.match;
      switch (m.type) {
        case 'bold':
          out.add(TextSpan(
            text: match.group(1),
            style: baseStyle?.copyWith(color: syntaxColor),
          ));
          out.add(TextSpan(
            text: match.group(2),
            style: baseStyle?.copyWith(
              fontWeight: FontWeight.bold,
              color: bodyColor,
            ),
          ));
          out.add(TextSpan(
            text: match.group(3),
            style: baseStyle?.copyWith(color: syntaxColor),
          ));
        case 'italic':
          out.add(TextSpan(
            text: match.group(1),
            style: baseStyle?.copyWith(color: syntaxColor),
          ));
          out.add(TextSpan(
            text: match.group(2),
            style: baseStyle?.copyWith(
              fontStyle: FontStyle.italic,
              color: bodyColor,
            ),
          ));
          out.add(TextSpan(
            text: match.group(3),
            style: baseStyle?.copyWith(color: syntaxColor),
          ));
        case 'code':
          out.add(TextSpan(
            text: match.group(1),
            style: baseStyle?.copyWith(
              color: syntaxColor,
              fontFamily: 'monospace',
            ),
          ));
          out.add(TextSpan(
            text: match.group(2),
            style: baseStyle?.copyWith(
              fontFamily: 'monospace',
              color: bodyColor,
            ),
          ));
          out.add(TextSpan(
            text: match.group(3),
            style: baseStyle?.copyWith(
              color: syntaxColor,
              fontFamily: 'monospace',
            ),
          ));
      }

      cursor = m.end;
    }

    // Remaining plain text
    if (cursor < text.length) {
      out.add(TextSpan(
        text: text.substring(cursor),
        style: baseStyle,
      ));
    }
  }

  // --- Regex patterns (inline only) ---

  static final _boldRegex = RegExp(r'(\*\*|__)(.+?)(\1)');
  static final _italicRegex =
      RegExp(r'(?<!\*)(\*)(?!\*)(.+?)(?<!\*)(\1)(?!\*)');
  static final _codeRegex = RegExp(r'(`)([^`]+)(`)');
}

/// Helper for tracking inline pattern matches.
class _InlineMatch {
  final int start;
  final int end;
  final String type;
  final RegExpMatch match;

  _InlineMatch(this.start, this.end, this.type, this.match);
}
