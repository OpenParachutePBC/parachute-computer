import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'recording_waveform.dart';

/// Calm recording overlay for Daily voice journaling
///
/// Replaces the streaming transcription overlay with a focused recording
/// experience: waveform visualization, wall-clock timer, stop + cancel buttons.
/// No live text — just record and think.
class DailyRecordingOverlay extends StatefulWidget {
  /// Stream of audio amplitude values (0.0 - 1.0)
  final Stream<double> amplitudeStream;

  /// Called when user taps Done (stop recording)
  final VoidCallback onStop;

  /// Called when user taps Discard
  final VoidCallback onCancel;

  const DailyRecordingOverlay({
    super.key,
    required this.amplitudeStream,
    required this.onStop,
    required this.onCancel,
  });

  @override
  State<DailyRecordingOverlay> createState() => _DailyRecordingOverlayState();
}

class _DailyRecordingOverlayState extends State<DailyRecordingOverlay> {
  Duration _duration = Duration.zero;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _duration = _duration + const Duration(seconds: 1);
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _durationText {
    final hours = _duration.inHours;
    final minutes = _duration.inMinutes % 60;
    final seconds = _duration.inSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Recording header with red dot + timer
            _buildRecordingHeader(isDark),
            const SizedBox(height: 24),

            // Waveform visualization
            RecordingWaveform(
              amplitudeStream: widget.amplitudeStream,
              height: 80,
              color: BrandColors.forest,
            ),
            const SizedBox(height: 24),

            // Control buttons
            _buildControls(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: BrandColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Pulsing recording dot
          _PulsingDot(),
          const SizedBox(width: 12),

          // Timer
          Text(
            _durationText,
            style: TextStyle(
              color: BrandColors.error,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(bool isDark) {
    return Row(
      children: [
        // Discard button
        Expanded(
          child: SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                widget.onCancel();
              },
              icon: Icon(Icons.close, size: 20, color: BrandColors.driftwood),
              label: Text(
                'Discard',
                style: TextStyle(color: BrandColors.driftwood),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: BrandColors.driftwood.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),

        // Done button (stop recording)
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () {
                HapticFeedback.heavyImpact();
                widget.onStop();
              },
              icon: const Icon(Icons.check, size: 20),
              label: const Text('Done'),
              style: ElevatedButton.styleFrom(
                backgroundColor: BrandColors.forest,
                foregroundColor: BrandColors.softWhite,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pulsing red recording indicator dot
class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: BrandColors.error.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
