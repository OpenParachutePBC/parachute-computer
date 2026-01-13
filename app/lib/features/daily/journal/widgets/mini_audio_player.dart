import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../recorder/providers/service_providers.dart';
import '../../recorder/services/audio_service.dart';

/// A mini audio player bar shown at the bottom of the journal screen when audio is playing.
///
/// Shows current playback position, pause/resume, stop controls in a compact bar.
class MiniAudioPlayer extends ConsumerStatefulWidget {
  final String? currentAudioPath;
  final String? entryTitle;
  final VoidCallback? onStop;

  const MiniAudioPlayer({
    super.key,
    this.currentAudioPath,
    this.entryTitle,
    this.onStop,
  });

  @override
  ConsumerState<MiniAudioPlayer> createState() => _MiniAudioPlayerState();
}

class _MiniAudioPlayerState extends ConsumerState<MiniAudioPlayer> {
  bool _isPlaying = false;
  bool _isPaused = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  AudioService? _audioService;

  @override
  void initState() {
    super.initState();
    _initializeAudio();
  }

  Future<void> _initializeAudio() async {
    _audioService = ref.read(audioServiceProvider);
    await _audioService!.initialize();

    // Listen to position stream
    _positionSubscription = _audioService!.positionStream.listen((position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
        });
      }
    });

    // Listen to duration stream
    _durationSubscription = _audioService!.durationStream.listen((duration) {
      if (duration != null && mounted) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });

    // Listen to playing stream
    _playingSubscription = _audioService!.playingStream.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          if (!playing) {
            _isPaused = false;
            // Notify parent that playback stopped
            widget.onStop?.call();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_audioService == null) return;

    if (_isPlaying && !_isPaused) {
      await _audioService!.pausePlayback();
      setState(() => _isPaused = true);
    } else if (_isPaused) {
      await _audioService!.resumePlayback();
      setState(() => _isPaused = false);
    }
  }

  Future<void> _stopPlayback() async {
    if (_audioService == null) return;
    await _audioService!.stopPlayback();
    setState(() {
      _currentPosition = Duration.zero;
      _isPlaying = false;
      _isPaused = false;
    });
    widget.onStop?.call();
  }

  Future<void> _seekTo(double value) async {
    if (_audioService == null) return;
    final position = Duration(milliseconds: value.toInt());
    await _audioService!.seekTo(position);
    setState(() => _currentPosition = position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if not playing and not paused
    if (!_isPlaying && !_isPaused) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = widget.entryTitle ?? 'Playing audio';

    // Use AnimatedContainer for smooth appearance
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurfaceElevated
              : BrandColors.softWhite,
          border: Border(
            top: BorderSide(
              color: BrandColors.turquoise.withValues(alpha: 0.5),
              width: 2,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar (thin, at top)
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                activeTrackColor: BrandColors.turquoise,
                inactiveTrackColor: BrandColors.turquoise.withValues(alpha: 0.2),
                thumbColor: BrandColors.turquoise,
              ),
              child: Slider(
                value: _currentPosition.inMilliseconds.toDouble().clamp(
                  0.0,
                  _totalDuration.inMilliseconds > 0
                      ? _totalDuration.inMilliseconds.toDouble()
                      : 1.0,
                ),
                max: _totalDuration.inMilliseconds > 0
                    ? _totalDuration.inMilliseconds.toDouble()
                    : 1.0,
                onChanged: _seekTo,
              ),
            ),

            // Controls row
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8, bottom: 8),
              child: Row(
                children: [
                  // Audio icon
                  Icon(
                    Icons.graphic_eq,
                    color: BrandColors.turquoise,
                    size: 20,
                  ),
                  const SizedBox(width: 12),

                  // Title and time
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_formatDuration(_currentPosition)} / ${_formatDuration(_totalDuration)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Play/Pause button
                  IconButton(
                    icon: Icon(
                      _isPaused ? Icons.play_arrow : Icons.pause,
                      color: BrandColors.turquoise,
                    ),
                    onPressed: _togglePlayback,
                    tooltip: _isPaused ? 'Resume' : 'Pause',
                  ),

                  // Stop button
                  IconButton(
                    icon: Icon(
                      Icons.stop,
                      color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                    ),
                    onPressed: _stopPlayback,
                    tooltip: 'Stop',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
