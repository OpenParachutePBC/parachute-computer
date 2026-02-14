import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/transcription_history_service.dart';

/// Progress state for active transcription
class TranscriptionProgressState {
  final bool isActive;
  final double progress; // 0.0 to 1.0
  final String status;
  final Duration? audioDuration;
  final Duration? estimatedTimeRemaining;
  final DateTime? startedAt;
  final int? audioDurationMs; // For recording history

  const TranscriptionProgressState({
    this.isActive = false,
    this.progress = 0.0,
    this.status = '',
    this.audioDuration,
    this.estimatedTimeRemaining,
    this.startedAt,
    this.audioDurationMs,
  });

  TranscriptionProgressState copyWith({
    bool? isActive,
    double? progress,
    String? status,
    Duration? audioDuration,
    Duration? estimatedTimeRemaining,
    DateTime? startedAt,
    int? audioDurationMs,
  }) {
    return TranscriptionProgressState(
      isActive: isActive ?? this.isActive,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      audioDuration: audioDuration ?? this.audioDuration,
      estimatedTimeRemaining: estimatedTimeRemaining ?? this.estimatedTimeRemaining,
      startedAt: startedAt ?? this.startedAt,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
    );
  }

  /// Get formatted time remaining string
  String get timeRemainingText {
    if (estimatedTimeRemaining == null) return '';
    final seconds = estimatedTimeRemaining!.inSeconds;
    if (seconds < 2) return 'Almost done...';
    if (seconds < 60) return '~${seconds}s remaining';
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '~${minutes}m ${secs}s remaining';
  }

  /// Get formatted progress percentage
  String get progressText => '${(progress * 100).toInt()}%';
}

/// Notifier for transcription progress with historical time estimates
class TranscriptionProgressNotifier extends StateNotifier<TranscriptionProgressState> {
  Timer? _progressTimer;
  final TranscriptionHistoryService _historyService = TranscriptionHistoryService();

  TranscriptionProgressNotifier() : super(const TranscriptionProgressState());

  /// Start tracking transcription progress
  ///
  /// Uses historical data to estimate time remaining more accurately.
  Future<void> startTranscription({required int audioDurationSeconds}) async {
    final audioDurationMs = audioDurationSeconds * 1000;
    final audioDuration = Duration(seconds: audioDurationSeconds);

    // Get estimated time from historical data
    final estimatedProcessingTime = await _historyService.estimateTranscriptionTime(audioDurationMs);

    final stats = _historyService.getStats();
    debugPrint(
      '[TranscriptionProgress] Starting transcription: ${audioDurationSeconds}s audio, '
      'estimated ${estimatedProcessingTime.inSeconds}s processing time '
      '(based on ${stats.recordCount} historical records, '
      'median ${stats.medianSpeedRatio.toStringAsFixed(1)}x speed)',
    );

    state = TranscriptionProgressState(
      isActive: true,
      progress: 0.05,
      status: 'Transcribing...',
      audioDuration: audioDuration,
      estimatedTimeRemaining: estimatedProcessingTime,
      startedAt: DateTime.now(),
      audioDurationMs: audioDurationMs,
    );

    // Start progress simulation timer
    _startProgressTimer(estimatedProcessingTime);
  }

  void _startProgressTimer(Duration estimatedTotal) {
    _progressTimer?.cancel();

    const updateInterval = Duration(milliseconds: 200);
    final totalMs = estimatedTotal.inMilliseconds;

    _progressTimer = Timer.periodic(updateInterval, (timer) {
      if (!state.isActive) {
        timer.cancel();
        return;
      }

      final elapsed = DateTime.now().difference(state.startedAt!);
      final elapsedMs = elapsed.inMilliseconds;

      // Calculate estimated progress (cap at 95% until actually complete)
      var estimatedProgress = (elapsedMs / totalMs).clamp(0.0, 0.95);

      // Calculate remaining time
      final remainingMs = (totalMs - elapsedMs).clamp(0, totalMs * 2);
      final remaining = Duration(milliseconds: remainingMs.round());

      state = state.copyWith(
        progress: estimatedProgress,
        estimatedTimeRemaining: remaining,
        status: _getStatusForProgress(estimatedProgress),
      );
    });
  }

  String _getStatusForProgress(double progress) {
    if (progress < 0.3) return 'Transcribing...';
    if (progress < 0.6) return 'Processing audio...';
    if (progress < 0.9) return 'Finalizing...';
    return 'Almost done...';
  }

  /// Mark transcription as complete and record timing for future estimates
  Future<void> complete() async {
    _progressTimer?.cancel();

    // Record the actual transcription time for future estimates
    if (state.startedAt != null && state.audioDurationMs != null) {
      final actualTranscriptionTime = DateTime.now().difference(state.startedAt!);

      await _historyService.recordTranscription(
        audioDurationMs: state.audioDurationMs!,
        transcriptionTimeMs: actualTranscriptionTime.inMilliseconds,
      );

      debugPrint(
        '[TranscriptionProgress] Completed in ${actualTranscriptionTime.inMilliseconds}ms '
        '(${(state.audioDurationMs! / actualTranscriptionTime.inMilliseconds).toStringAsFixed(1)}x real-time)',
      );
    }

    state = state.copyWith(
      isActive: false,
      progress: 1.0,
      status: 'Complete!',
      estimatedTimeRemaining: Duration.zero,
    );

    // Clear state after a short delay
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!state.isActive) {
        state = const TranscriptionProgressState();
      }
    });
  }

  /// Mark transcription as failed
  void fail(String error) {
    _progressTimer?.cancel();
    state = state.copyWith(
      isActive: false,
      status: 'Failed: $error',
    );
  }

  /// Cancel tracking
  void cancel() {
    _progressTimer?.cancel();
    state = const TranscriptionProgressState();
  }

  /// Get transcription performance statistics
  TranscriptionStats getStats() => _historyService.getStats();

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }
}

/// Provider for transcription progress
final transcriptionProgressProvider = StateNotifierProvider<
    TranscriptionProgressNotifier, TranscriptionProgressState>((ref) {
  return TranscriptionProgressNotifier();
});
