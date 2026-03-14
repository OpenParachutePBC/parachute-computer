import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Animated waveform visualization for voice recording
///
/// Displays a row of animated bars driven by an audio amplitude stream.
/// Uses a rolling buffer of recent amplitude values for a smooth waveform effect.
class RecordingWaveform extends StatefulWidget {
  /// Stream of audio amplitude values (0.0 - 1.0)
  final Stream<double> amplitudeStream;

  /// Number of bars to display
  final int barCount;

  /// Height of the waveform widget
  final double height;

  /// Color of the bars
  final Color? color;

  const RecordingWaveform({
    super.key,
    required this.amplitudeStream,
    this.barCount = 40,
    this.height = 80,
    this.color,
  });

  @override
  State<RecordingWaveform> createState() => _RecordingWaveformState();
}

class _RecordingWaveformState extends State<RecordingWaveform>
    with SingleTickerProviderStateMixin {
  late final List<double> _amplitudes;
  late final AnimationController _animationController;
  StreamSubscription<double>? _amplitudeSubscription;

  @override
  void initState() {
    super.initState();
    _amplitudes = List.filled(widget.barCount, 0.0);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );

    _amplitudeSubscription = widget.amplitudeStream.listen((amplitude) {
      if (!mounted) return;
      setState(() {
        // Shift all values left and add new one at end
        for (var i = 0; i < _amplitudes.length - 1; i++) {
          _amplitudes[i] = _amplitudes[i + 1];
        }
        _amplitudes[_amplitudes.length - 1] = amplitude.clamp(0.0, 1.0);
      });
    });
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(double.infinity, widget.height),
        painter: _WaveformPainter(
          amplitudes: _amplitudes,
          color: widget.color ?? BrandColors.forest,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final Color color;

  _WaveformPainter({required this.amplitudes, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final barWidth = size.width / amplitudes.length;
    final gap = barWidth * 0.3;
    final effectiveBarWidth = barWidth - gap;
    final centerY = size.height / 2;
    final maxBarHeight = size.height * 0.8;
    final minBarHeight = 3.0;
    final radius = Radius.circular(effectiveBarWidth / 2);

    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;

    for (var i = 0; i < amplitudes.length; i++) {
      final amplitude = amplitudes[i];
      // Use sqrt for more visible response at low amplitudes
      final barHeight = max(minBarHeight, sqrt(amplitude) * maxBarHeight);
      final x = i * barWidth + gap / 2;
      final top = centerY - barHeight / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, effectiveBarWidth, barHeight),
        radius,
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return true; // Always repaint since amplitudes change frequently
  }
}
