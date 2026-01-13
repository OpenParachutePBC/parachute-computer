import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/recorder/services/live_transcription_service_v3.dart';

/// Visual audio debug overlay showing real-time audio metrics
///
/// Displays:
/// - Raw audio energy (before filtering)
/// - Clean audio energy (after filtering)
/// - Filter reduction percentage
/// - Speech detection status
/// - Real-time graph over last 5 seconds
class AudioDebugOverlay extends ConsumerStatefulWidget {
  final Stream<AudioDebugMetrics> metricsStream;

  const AudioDebugOverlay({super.key, required this.metricsStream});

  @override
  ConsumerState<AudioDebugOverlay> createState() => _AudioDebugOverlayState();
}

class _AudioDebugOverlayState extends ConsumerState<AudioDebugOverlay> {
  final List<AudioDebugMetrics> _history = [];
  static const int _maxHistorySeconds = 5;
  static const int _maxHistoryPoints =
      _maxHistorySeconds * 100; // 100 samples/sec

  AudioDebugMetrics? _latestMetrics;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    widget.metricsStream.listen((metrics) {
      if (mounted) {
        setState(() {
          _latestMetrics = metrics;
          _history.add(metrics);

          // Keep only last 5 seconds of data
          if (_history.length > _maxHistoryPoints) {
            _history.removeAt(0);
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_latestMetrics == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      right: 16,
      bottom: 100,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.85),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: _isExpanded ? 320 : 60,
          height: _isExpanded ? 280 : 60,
          padding: const EdgeInsets.all(12),
          child: _isExpanded ? _buildExpandedView() : _buildCollapsedView(),
        ),
      ),
    );
  }

  Widget _buildCollapsedView() {
    final isSpeech = _latestMetrics!.isSpeech;

    return GestureDetector(
      onTap: () => setState(() => _isExpanded = true),
      child: Center(
        child: Icon(
          Icons.graphic_eq,
          color: isSpeech ? Colors.green : Colors.grey,
          size: 32,
        ),
      ),
    );
  }

  Widget _buildExpandedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Audio Debug',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => setState(() => _isExpanded = false),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Graph
        Expanded(child: _buildGraph()),
        const SizedBox(height: 8),

        // Metrics
        _buildMetrics(),
      ],
    );
  }

  Widget _buildGraph() {
    if (_history.isEmpty) {
      return const Center(
        child: Text(
          'Collecting data...',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
      );
    }

    return CustomPaint(
      painter: AudioGraphPainter(history: _history, threshold: 200.0),
      size: Size.infinite,
    );
  }

  Widget _buildMetrics() {
    final metrics = _latestMetrics!;

    return SizedBox(
      height: 80, // Fixed height to prevent overflow
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildMetricRow(
            'Raw',
            metrics.rawEnergy.toStringAsFixed(0),
            Colors.orange,
          ),
          const SizedBox(height: 4),
          _buildMetricRow(
            'Clean',
            metrics.cleanEnergy.toStringAsFixed(0),
            Colors.blue,
          ),
          const SizedBox(height: 4),
          _buildMetricRow(
            'Filtered',
            '${metrics.filterReduction.toStringAsFixed(1)}%',
            Colors.green,
          ),
          const SizedBox(height: 4),
          _buildMetricRow(
            'Status',
            metrics.isSpeech ? 'SPEECH' : 'Silence',
            metrics.isSpeech ? Colors.green : Colors.grey,
          ),
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, String value, Color color) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Only show content if we have reasonable space
        if (constraints.maxWidth < 100) {
          return const SizedBox.shrink();
        }

        return Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Expanded(
              flex: 2,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
                overflow: TextOverflow.clip,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              flex: 3,
              child: Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.clip,
                textAlign: TextAlign.end,
                maxLines: 1,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Custom painter for audio energy graph
class AudioGraphPainter extends CustomPainter {
  final List<AudioDebugMetrics> history;
  final double threshold;

  AudioGraphPainter({required this.history, required this.threshold});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    // Find max energy for scaling
    double maxEnergy = threshold * 2; // Default scale
    for (final metrics in history) {
      maxEnergy = max(maxEnergy, max(metrics.rawEnergy, metrics.cleanEnergy));
    }

    // Draw threshold line
    final thresholdY = size.height - (threshold / maxEnergy * size.height);
    final thresholdPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      thresholdPaint,
    );

    // Draw raw energy line (orange)
    _drawEnergyLine(
      canvas,
      size,
      maxEnergy,
      (m) => m.rawEnergy,
      Colors.orange.withValues(alpha: 0.6),
    );

    // Draw clean energy line (blue)
    _drawEnergyLine(canvas, size, maxEnergy, (m) => m.cleanEnergy, Colors.blue);

    // Draw speech indicators (green dots)
    _drawSpeechIndicators(canvas, size, maxEnergy);
  }

  void _drawEnergyLine(
    Canvas canvas,
    Size size,
    double maxEnergy,
    double Function(AudioDebugMetrics) getValue,
    Color color,
  ) {
    if (history.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final pointSpacing = size.width / (history.length - 1);

    for (int i = 0; i < history.length; i++) {
      final energy = getValue(history[i]);
      final x = i * pointSpacing;
      final y = size.height - (energy / maxEnergy * size.height);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  void _drawSpeechIndicators(Canvas canvas, Size size, double maxEnergy) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.fill;

    final pointSpacing = size.width / (history.length - 1);

    for (int i = 0; i < history.length; i++) {
      if (history[i].isSpeech) {
        final x = i * pointSpacing;
        canvas.drawCircle(Offset(x, size.height - 2), 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(AudioGraphPainter oldDelegate) {
    return oldDelegate.history.length != history.length;
  }
}
