import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/capture_providers.dart';
import '../widgets/lined_paper_background.dart';

/// Screen for freehand handwriting/drawing.
///
/// Features:
/// - Drawing canvas with stylus/touch support
/// - Toggle between blank and lined paper backgrounds
/// - Pen color and size selection
/// - Eraser mode
/// - Export to PNG for journal entry
class HandwritingScreen extends ConsumerStatefulWidget {
  /// Callback when the handwriting is saved
  final void Function(String imagePath, bool linedBackground)? onSaved;

  const HandwritingScreen({
    super.key,
    this.onSaved,
  });

  @override
  ConsumerState<HandwritingScreen> createState() => _HandwritingScreenState();
}

class _HandwritingScreenState extends ConsumerState<HandwritingScreen> {
  // Drawing state
  final List<_Stroke> _strokes = [];
  _Stroke? _currentStroke;

  // Tool settings
  bool _showLinedBackground = false;
  Color _currentColor = Colors.black;
  double _strokeWidth = 3.0;
  bool _eraserMode = false;

  // Canvas key for export
  final GlobalKey _canvasKey = GlobalKey();

  // Whether we're currently saving
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? Colors.grey[900]! : Colors.white;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Handwriting'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _handleCancel,
        ),
        actions: [
          // Toggle lined paper
          IconButton(
            icon: Icon(
              _showLinedBackground ? Icons.grid_off : Icons.grid_on,
              color: _showLinedBackground ? BrandColors.turquoise : null,
            ),
            onPressed: () {
              setState(() {
                _showLinedBackground = !_showLinedBackground;
              });
            },
            tooltip: _showLinedBackground ? 'Hide lines' : 'Show lines',
          ),
          // Clear canvas
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _strokes.isEmpty ? null : _clearCanvas,
            tooltip: 'Clear',
          ),
          // Save
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            onPressed: _strokes.isEmpty || _isSaving ? null : _saveAndClose,
            tooltip: 'Save',
          ),
        ],
      ),
      body: Column(
        children: [
          // Drawing canvas
          Expanded(
            child: RepaintBoundary(
              key: _canvasKey,
              child: Container(
                color: backgroundColor,
                child: Stack(
                  children: [
                    // Lined background (optional)
                    if (_showLinedBackground)
                      LinedPaperBackground(
                        lineColor: isDark
                            ? Colors.grey[700]!
                            : const Color(0xFFE0E0E0),
                      ),

                    // Drawing canvas
                    GestureDetector(
                      onPanStart: _onPanStart,
                      onPanUpdate: _onPanUpdate,
                      onPanEnd: _onPanEnd,
                      child: CustomPaint(
                        painter: _StrokePainter(
                          strokes: _strokes,
                          currentStroke: _currentStroke,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Toolbar
          _buildToolbar(isDark),
        ],
      ),
    );
  }

  Widget _buildToolbar(bool isDark) {
    final toolbarColor = isDark ? Colors.grey[850] : Colors.grey[100];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: toolbarColor,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.grey[700]! : Colors.grey[300]!,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Color picker
            _buildColorButton(Colors.black, isDark),
            _buildColorButton(BrandColors.turquoise, isDark),
            _buildColorButton(BrandColors.forest, isDark),
            _buildColorButton(Colors.red, isDark),
            _buildColorButton(Colors.blue, isDark),

            const SizedBox(width: 16),

            // Eraser toggle
            _buildToolButton(
              icon: Icons.auto_fix_high,
              isSelected: _eraserMode,
              onTap: () {
                setState(() {
                  _eraserMode = !_eraserMode;
                });
              },
              tooltip: 'Eraser',
              isDark: isDark,
            ),

            const Spacer(),

            // Stroke width slider
            SizedBox(
              width: 120,
              child: Slider(
                value: _strokeWidth,
                min: 1.0,
                max: 10.0,
                divisions: 9,
                activeColor: BrandColors.turquoise,
                onChanged: (value) {
                  setState(() {
                    _strokeWidth = value;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorButton(Color color, bool isDark) {
    final isSelected = _currentColor == color && !_eraserMode;

    return GestureDetector(
      onTap: () {
        setState(() {
          _currentColor = color;
          _eraserMode = false;
        });
      },
      child: Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected
                ? BrandColors.turquoise
                : (isDark ? Colors.grey[600]! : Colors.grey[400]!),
            width: isSelected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required String tooltip,
    required bool isDark,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isSelected
                ? BrandColors.turquoise.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? BrandColors.turquoise
                  : (isDark ? Colors.grey[600]! : Colors.grey[400]!),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isSelected
                ? BrandColors.turquoise
                : (isDark ? Colors.grey[400] : Colors.grey[600]),
          ),
        ),
      ),
    );
  }

  void _onPanStart(DragStartDetails details) {
    final point = details.localPosition;

    setState(() {
      _currentStroke = _Stroke(
        points: [_StrokePoint(point.dx, point.dy, 0.5)],
        color: _eraserMode ? Colors.white : _currentColor,
        strokeWidth: _eraserMode ? _strokeWidth * 3 : _strokeWidth,
        isEraser: _eraserMode,
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_currentStroke == null) return;

    final point = details.localPosition;

    setState(() {
      _currentStroke = _currentStroke!.copyWithPoint(
        _StrokePoint(point.dx, point.dy, 0.5),
      );
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_currentStroke == null) return;

    setState(() {
      _strokes.add(_currentStroke!);
      _currentStroke = null;
    });
  }

  void _clearCanvas() {
    setState(() {
      _strokes.clear();
      _currentStroke = null;
    });
  }

  void _handleCancel() {
    if (_strokes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    // Confirm discard
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard drawing?'),
        content: const Text('Your handwriting will not be saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: const Text('Discard'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndClose() async {
    if (_strokes.isEmpty || _isSaving) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // Capture the canvas as an image
      final boundary = _canvasKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      // Save to assets folder
      final captureService = ref.read(photoCaptureServiceProvider);
      final result = await captureService.saveImageBytes(
        pngBytes,
        'canvas',
        extension: 'png',
      );

      // Notify parent
      widget.onSaved?.call(result.relativePath, _showLinedBackground);

      // Close screen
      if (mounted) {
        Navigator.of(context).pop(result.relativePath);
      }
    } catch (e) {
      debugPrint('[HandwritingScreen] Error saving: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

/// A single stroke (continuous pen movement)
class _Stroke {
  final List<_StrokePoint> points;
  final Color color;
  final double strokeWidth;
  final bool isEraser;

  const _Stroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.isEraser = false,
  });

  _Stroke copyWithPoint(_StrokePoint point) {
    return _Stroke(
      points: [...points, point],
      color: color,
      strokeWidth: strokeWidth,
      isEraser: isEraser,
    );
  }
}

/// A point in a stroke with pressure
class _StrokePoint {
  final double x;
  final double y;
  final double pressure;

  const _StrokePoint(this.x, this.y, this.pressure);
}

/// Painter that draws all strokes
class _StrokePainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? currentStroke;

  _StrokePainter({
    required this.strokes,
    this.currentStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw completed strokes
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }

    // Draw current stroke
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!);
    }
  }

  void _drawStroke(Canvas canvas, _Stroke stroke) {
    if (stroke.points.isEmpty) return;

    // Convert to perfect_freehand points
    final inputPoints = stroke.points.map((p) {
      return PointVector(p.x, p.y, p.pressure);
    }).toList();

    // Get stroke outline using perfect_freehand
    final outlinePoints = getStroke(
      inputPoints,
      options: StrokeOptions(
        size: stroke.strokeWidth,
        thinning: 0.5,
        smoothing: 0.5,
        streamline: 0.5,
        start: StrokeEndOptions.start(
          taperEnabled: false,
          cap: true,
        ),
        end: StrokeEndOptions.end(
          taperEnabled: false,
          cap: true,
        ),
      ),
    );

    if (outlinePoints.isEmpty) return;

    // Create path from outline
    final path = Path();
    path.moveTo(outlinePoints.first.dx, outlinePoints.first.dy);
    for (int i = 1; i < outlinePoints.length; i++) {
      path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
    }
    path.close();

    // Draw
    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_StrokePainter oldDelegate) {
    return strokes != oldDelegate.strokes ||
        currentStroke != oldDelegate.currentStroke;
  }
}
