import 'package:flutter/material.dart';

/// A widget that draws horizontal lines like lined paper.
///
/// Used as a background for the handwriting canvas.
class LinedPaperBackground extends StatelessWidget {
  /// Spacing between lines in logical pixels.
  final double lineSpacing;

  /// Color of the lines.
  final Color lineColor;

  /// Whether to show a margin line on the left.
  final bool showMargin;

  /// Color of the margin line.
  final Color marginColor;

  const LinedPaperBackground({
    super.key,
    this.lineSpacing = 32.0,
    this.lineColor = const Color(0xFFE0E0E0),
    this.showMargin = false,
    this.marginColor = const Color(0xFFFFCDD2),
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LinedPaperPainter(
        lineSpacing: lineSpacing,
        lineColor: lineColor,
        showMargin: showMargin,
        marginColor: marginColor,
      ),
      size: Size.infinite,
    );
  }
}

class _LinedPaperPainter extends CustomPainter {
  final double lineSpacing;
  final Color lineColor;
  final bool showMargin;
  final Color marginColor;

  _LinedPaperPainter({
    required this.lineSpacing,
    required this.lineColor,
    required this.showMargin,
    required this.marginColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Draw horizontal lines
    double y = lineSpacing;
    while (y < size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        linePaint,
      );
      y += lineSpacing;
    }

    // Draw margin line if enabled
    if (showMargin) {
      final marginPaint = Paint()
        ..color = marginColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;

      const marginX = 48.0;
      canvas.drawLine(
        Offset(marginX, 0),
        Offset(marginX, size.height),
        marginPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_LinedPaperPainter oldDelegate) {
    return lineSpacing != oldDelegate.lineSpacing ||
        lineColor != oldDelegate.lineColor ||
        showMargin != oldDelegate.showMargin ||
        marginColor != oldDelegate.marginColor;
  }
}
