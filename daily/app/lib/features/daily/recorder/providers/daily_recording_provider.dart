import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'service_providers.dart';

/// State for Daily voice recording (no live transcription)
class DailyRecordingState {
  final bool isRecording;
  final bool isPaused;
  final Duration duration;
  final String? audioPath;

  const DailyRecordingState({
    this.isRecording = false,
    this.isPaused = false,
    this.duration = Duration.zero,
    this.audioPath,
  });

  DailyRecordingState copyWith({
    bool? isRecording,
    bool? isPaused,
    Duration? duration,
    String? audioPath,
  }) {
    return DailyRecordingState(
      isRecording: isRecording ?? this.isRecording,
      isPaused: isPaused ?? this.isPaused,
      duration: duration ?? this.duration,
      audioPath: audioPath ?? this.audioPath,
    );
  }
}

/// Simplified recording notifier for Daily — audio only, no live transcription
///
/// Starts/stops the AudioService recorder and provides an amplitude stream
/// for waveform visualization. Transcription happens post-hoc after recording.
class DailyRecordingNotifier extends StateNotifier<DailyRecordingState> {
  final Ref _ref;
  Timer? _durationTimer;
  StreamController<double>? _amplitudeController;
  Timer? _amplitudeTimer;

  DailyRecordingNotifier(this._ref) : super(const DailyRecordingState());

  /// Stream of audio amplitude values (0.0 - 1.0) for waveform visualization
  Stream<double> get amplitudeStream {
    _amplitudeController ??= StreamController<double>.broadcast();
    return _amplitudeController!.stream;
  }

  /// Start recording audio only (no transcription)
  Future<bool> startRecording() async {
    if (state.isRecording) return false;

    try {
      final audioService = _ref.read(audioServiceProvider);
      await audioService.ensureInitialized();
      final started = await audioService.startRecording();

      if (!started) {
        debugPrint('[DailyRecording] AudioService failed to start');
        return false;
      }

      HapticFeedback.mediumImpact();

      state = state.copyWith(
        isRecording: true,
        duration: Duration.zero,
        audioPath: null,
      );

      _startDurationTimer();
      _startAmplitudePolling();

      debugPrint('[DailyRecording] Recording started (audio only, no live transcription)');
      return true;
    } catch (e) {
      debugPrint('[DailyRecording] Failed to start: $e');
      return false;
    }
  }

  /// Stop recording and return the audio file path
  Future<String?> stopRecording() async {
    if (!state.isRecording) return null;

    _stopDurationTimer();
    _stopAmplitudePolling();

    try {
      final audioService = _ref.read(audioServiceProvider);
      final audioPath = await audioService.stopRecording();

      state = state.copyWith(
        isRecording: false,
        isPaused: false,
        audioPath: audioPath,
      );

      debugPrint('[DailyRecording] Recording stopped, audioPath: $audioPath');
      return audioPath;
    } catch (e) {
      debugPrint('[DailyRecording] Failed to stop: $e');
      state = state.copyWith(isRecording: false, isPaused: false);
      return null;
    }
  }

  /// Pause recording
  Future<bool> pauseRecording() async {
    if (!state.isRecording || state.isPaused) return false;

    try {
      final audioService = _ref.read(audioServiceProvider);
      final paused = await audioService.pauseRecording();
      if (!paused) return false;

      _stopDurationTimer();
      _stopAmplitudePolling();

      state = state.copyWith(isPaused: true);
      debugPrint('[DailyRecording] Recording paused at ${state.duration}');
      return true;
    } catch (e) {
      debugPrint('[DailyRecording] Failed to pause: $e');
      return false;
    }
  }

  /// Resume recording after pause
  Future<bool> resumeRecording() async {
    if (!state.isRecording || !state.isPaused) return false;

    try {
      final audioService = _ref.read(audioServiceProvider);
      final resumed = await audioService.resumeRecording();
      if (!resumed) return false;

      _startDurationTimer();
      _startAmplitudePolling();

      state = state.copyWith(isPaused: false);
      debugPrint('[DailyRecording] Recording resumed');
      return true;
    } catch (e) {
      debugPrint('[DailyRecording] Failed to resume: $e');
      return false;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!state.isRecording) return;

    _stopDurationTimer();
    _stopAmplitudePolling();

    try {
      final audioService = _ref.read(audioServiceProvider);
      await audioService.stopRecording();
      // Audio file is at a temp path — it will be cleaned up
    } catch (e) {
      debugPrint('[DailyRecording] Error during cancel: $e');
    }

    state = const DailyRecordingState();
    debugPrint('[DailyRecording] Recording cancelled');
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isRecording) {
        state = state.copyWith(
          duration: state.duration + const Duration(seconds: 1),
        );
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  /// Poll amplitude from the recorder for waveform visualization
  void _startAmplitudePolling() {
    _amplitudeController ??= StreamController<double>.broadcast();
    _amplitudeTimer?.cancel();
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      if (!state.isRecording) return;
      try {
        final audioService = _ref.read(audioServiceProvider);
        final amplitude = await audioService.recorder.getAmplitude();
        // Convert dBFS to 0.0-1.0 range
        // dBFS ranges from -160 (silence) to 0 (max)
        // Map -60..0 to 0.0..1.0 for useful visualization range
        final dbfs = amplitude.current;
        final normalized = ((dbfs + 60) / 60).clamp(0.0, 1.0);
        _amplitudeController?.add(normalized);
      } catch (_) {
        // Recorder may not be ready — skip this sample
      }
    });
  }

  void _stopAmplitudePolling() {
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
  }

  @override
  void dispose() {
    _stopDurationTimer();
    _stopAmplitudePolling();
    _amplitudeController?.close();
    super.dispose();
  }
}

/// Provider for Daily recording control (audio only, no live transcription)
final dailyRecordingProvider =
    StateNotifierProvider<DailyRecordingNotifier, DailyRecordingState>((ref) {
  return DailyRecordingNotifier(ref);
});
