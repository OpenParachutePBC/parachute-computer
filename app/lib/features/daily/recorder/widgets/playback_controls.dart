import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/recorder/providers/service_providers.dart';
import 'package:parachute/core/services/transcription/audio_service.dart';

class PlaybackControls extends ConsumerStatefulWidget {
  final String filePath;
  final Duration duration;
  final VoidCallback? onDelete;

  const PlaybackControls({
    super.key,
    required this.filePath,
    required this.duration,
    this.onDelete,
  });

  @override
  ConsumerState<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends ConsumerState<PlaybackControls> {
  bool _isPlaying = false;
  bool _isPaused = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  bool _isSeeking = false;
  AudioService? _audioService; // Store service reference

  @override
  void initState() {
    super.initState();
    _totalDuration = widget.duration;
    _initializeAudio();
  }

  Future<void> _initializeAudio() async {
    _audioService = ref.read(audioServiceProvider);
    await _audioService!.initialize();

    // Listen to position stream
    _positionSubscription = _audioService!.positionStream.listen((position) {
      if (!_isSeeking && mounted) {
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

    // Always stop playback when widget is disposed (don't use ref after dispose)
    _audioService?.stopPlayback();

    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_audioService == null) return;
    final audioService = _audioService!;

    if (_isPlaying && !_isPaused) {
      // Pause playback
      await audioService.pausePlayback();
      setState(() {
        _isPaused = true;
      });
    } else if (_isPaused) {
      // Resume playback
      await audioService.resumePlayback();
      setState(() {
        _isPaused = false;
      });
    } else {
      // Start playback
      if (widget.filePath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio file not available for this recording'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      final success = await audioService.playRecording(widget.filePath);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to play recording'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    if (_audioService == null) return;

    if (_isPlaying) {
      await _audioService!.stopPlayback();
    }
    if (mounted) {
      setState(() {
        _currentPosition = Duration.zero;
      });
    }
  }

  Future<void> _seekTo(Duration position) async {
    if (_audioService == null) return;

    setState(() {
      _isSeeking = true;
      _currentPosition = position;
    });
    await _audioService!.seekTo(position);
    setState(() {
      _isSeeking = false;
    });
  }

  Future<void> _skip(int seconds) async {
    final newPosition = _currentPosition + Duration(seconds: seconds);
    if (newPosition < Duration.zero) {
      await _seekTo(Duration.zero);
    } else if (newPosition > _totalDuration) {
      await _seekTo(_totalDuration);
    } else {
      await _seekTo(newPosition);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withAlpha(51),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seekable slider
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              // Clamp value to prevent assertion error when position exceeds duration
              value: _currentPosition.inMilliseconds.toDouble().clamp(
                0.0,
                _totalDuration.inMilliseconds > 0
                    ? _totalDuration.inMilliseconds.toDouble()
                    : 1.0,
              ),
              max: _totalDuration.inMilliseconds > 0
                  ? _totalDuration.inMilliseconds.toDouble()
                  : 1.0,
              onChanged: (value) {
                setState(() {
                  _isSeeking = true;
                  _currentPosition = Duration(milliseconds: value.toInt());
                });
              },
              onChangeEnd: (value) async {
                await _seekTo(Duration(milliseconds: value.toInt()));
              },
            ),
          ),
          // Time display
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_currentPosition),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  _formatDuration(_totalDuration),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Skip backward 10s
              IconButton(
                icon: const Icon(Icons.replay_10),
                onPressed: () => _skip(-10),
                tooltip: 'Skip back 10s',
              ),
              const SizedBox(width: 8),
              // Stop button
              if (_isPlaying)
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: _stopPlayback,
                  tooltip: 'Stop',
                ),
              // Play/Pause button
              IconButton(
                icon: Icon(
                  _isPlaying && !_isPaused
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 48,
                ),
                onPressed: _togglePlayback,
                color: Theme.of(context).colorScheme.primary,
                tooltip: _isPlaying && !_isPaused ? 'Pause' : 'Play',
              ),
              const SizedBox(width: 8),
              // Skip forward 10s
              IconButton(
                icon: const Icon(Icons.forward_10),
                onPressed: () => _skip(10),
                tooltip: 'Skip forward 10s',
              ),
              // Delete button
              if (widget.onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Delete Recording'),
                        content: const Text(
                          'Are you sure you want to delete this recording?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onDelete!();
                            },
                            child: const Text(
                              'Delete',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  color: Colors.red,
                  tooltip: 'Delete',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
