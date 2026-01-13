import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../../../core/theme/design_tokens.dart';

/// A compact inline audio player for chat messages.
///
/// Displays a play/pause button, progress bar, and duration.
/// Used when audio files are referenced in markdown messages.
class InlineAudioPlayer extends StatefulWidget {
  final String audioPath;
  final String? title;

  const InlineAudioPlayer({
    super.key,
    required this.audioPath,
    this.title,
  });

  @override
  State<InlineAudioPlayer> createState() => _InlineAudioPlayerState();
}

class _InlineAudioPlayerState extends State<InlineAudioPlayer> {
  late AudioPlayer _player;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _initPlayer();
  }

  bool _isUrl(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
  }

  Future<void> _initPlayer() async {
    try {
      // Handle remote URLs vs local files
      if (_isUrl(widget.audioPath)) {
        await _player.setUrl(widget.audioPath);
      } else {
        final file = File(widget.audioPath);
        if (!await file.exists()) {
          setState(() {
            _hasError = true;
            _errorMessage = 'File not found';
          });
          return;
        }
        await _player.setFilePath(widget.audioPath);
      }

      _positionSub = _player.positionStream.listen((pos) {
        if (mounted) setState(() => _position = pos);
      });

      _durationSub = _player.durationStream.listen((dur) {
        if (dur != null && mounted) setState(() => _duration = dur);
      });

      _stateSub = _player.playerStateStream.listen((state) {
        if (mounted) setState(() {});
        // Reset position when playback completes
        if (state.processingState == ProcessingState.completed) {
          _player.seek(Duration.zero);
          _player.pause();
        }
      });

      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  void _seek(double value) {
    _player.seek(Duration(milliseconds: value.toInt()));
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_hasError) {
      return _buildErrorState(isDark);
    }

    if (!_isInitialized) {
      return _buildLoadingState(isDark);
    }

    return _buildPlayer(isDark);
  }

  Widget _buildErrorState(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: BrandColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 16, color: BrandColors.error),
          const SizedBox(width: Spacing.xs),
          Text(
            _errorMessage ?? 'Audio error',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: BrandColors.error,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(BrandColors.turquoise),
            ),
          ),
          const SizedBox(width: Spacing.xs),
          Text(
            'Loading audio...',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(bool isDark) {
    final isPlaying = _player.playing;

    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: BrandColors.turquoise.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play/Pause button
          GestureDetector(
            onTap: _togglePlayback,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: BrandColors.turquoise,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),

          // Progress and duration
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.title != null)
                  Text(
                    widget.title!,
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      fontWeight: FontWeight.w500,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                          activeTrackColor: BrandColors.turquoise,
                          inactiveTrackColor: BrandColors.turquoise.withValues(alpha: 0.2),
                          thumbColor: BrandColors.turquoise,
                        ),
                        child: Slider(
                          value: _position.inMilliseconds.toDouble().clamp(
                            0.0,
                            _duration.inMilliseconds > 0
                                ? _duration.inMilliseconds.toDouble()
                                : 1.0,
                          ),
                          max: _duration.inMilliseconds > 0
                              ? _duration.inMilliseconds.toDouble()
                              : 1.0,
                          onChanged: _seek,
                        ),
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
