import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/live_transcription_service_v3.dart';
import 'service_providers.dart';

/// Provider for the AutoPauseTranscriptionService instance
///
/// This service handles streaming transcription with VAD-based chunking.
/// It's initialized asynchronously and cached for the app lifetime.
final autoPauseTranscriptionServiceProvider = FutureProvider<AutoPauseTranscriptionService>((ref) async {
  final transcriptionAdapter = ref.watch(transcriptionServiceAdapterProvider);
  final service = AutoPauseTranscriptionService(transcriptionAdapter);
  await service.initialize();

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// Provider for streaming transcription state
///
/// This wraps the AutoPauseTranscriptionService's streaming state stream
/// and exposes it as a Riverpod provider for easy UI integration.
final streamingTranscriptionProvider = StreamProvider.autoDispose<StreamingTranscriptionState>((ref) {
  final transcriptionService = ref.watch(autoPauseTranscriptionServiceProvider);

  // Return the streaming state stream
  return transcriptionService.when(
    data: (service) => service.streamingStateStream,
    loading: () => Stream.value(const StreamingTranscriptionState()),
    error: (e, st) {
      debugPrint('[StreamingTranscription] Init error: $e');
      return Stream.error(e, st);
    },
  );
});

/// Provider for interim text only (for simpler UI bindings)
final interimTextProvider = StreamProvider.autoDispose<String>((ref) {
  final transcriptionService = ref.watch(autoPauseTranscriptionServiceProvider);

  return transcriptionService.when(
    data: (service) => service.interimTextStream,
    loading: () => Stream.value(''),
    error: (e, st) => Stream.value(''),
  );
});

/// Provider for VAD activity (speech detection)
final vadActivityProvider = StreamProvider.autoDispose<bool>((ref) {
  final transcriptionService = ref.watch(autoPauseTranscriptionServiceProvider);

  return transcriptionService.when(
    data: (service) => service.vadActivityStream,
    loading: () => Stream.value(false),
    error: (e, st) => Stream.value(false),
  );
});

/// Notifier for recording control with streaming support
class StreamingRecordingNotifier extends StateNotifier<StreamingRecordingState> {
  final Ref _ref;
  Timer? _durationTimer;
  AutoPauseTranscriptionService? _service;

  StreamingRecordingNotifier(this._ref) : super(const StreamingRecordingState());

  /// Start recording with streaming transcription
  Future<bool> startRecording() async {
    if (state.isRecording) {
      debugPrint('[StreamingRecording] Already recording, returning false');
      return false;
    }

    try {
      debugPrint('[StreamingRecording] Getting AutoPauseTranscriptionService...');
      final service = await _ref.read(autoPauseTranscriptionServiceProvider.future);
      _service = service;
      debugPrint('[StreamingRecording] Got service, starting recording...');

      final success = await service.startRecording();
      debugPrint('[StreamingRecording] startRecording returned: $success');

      if (success) {
        state = state.copyWith(
          isRecording: true,
          recordingStartTime: DateTime.now(),
        );
        _startDurationTimer();
        debugPrint('[StreamingRecording] Recording started successfully');
      } else {
        debugPrint('[StreamingRecording] Service returned false - check permissions or initialization');
      }
      return success;
    } catch (e, st) {
      debugPrint('[StreamingRecording] Failed to start: $e');
      debugPrint('[StreamingRecording] Stack trace: $st');
      return false;
    }
  }

  /// Stop recording
  Future<String?> stopRecording() async {
    debugPrint('[StreamingRecording] stopRecording called - isRecording: ${state.isRecording}');
    if (!state.isRecording) {
      debugPrint('[StreamingRecording] Not recording, returning null');
      return null;
    }

    if (_service == null) {
      debugPrint('[StreamingRecording] Service is null, returning null');
      _stopDurationTimer();
      return null;
    }

    try {
      debugPrint('[StreamingRecording] Calling service.stopRecording()...');
      final audioPath = await _service!.stopRecording();
      debugPrint('[StreamingRecording] Service returned audioPath: $audioPath');

      state = state.copyWith(
        isRecording: false,
        recordingStartTime: null,
      );

      return audioPath;
    } finally {
      // Always stop the timer, even if stopRecording throws
      _stopDurationTimer();
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!state.isRecording) return;

    try {
      if (_service != null) {
        await _service!.cancelRecording();
      }

      state = state.copyWith(
        isRecording: false,
        recordingStartTime: null,
      );
    } finally {
      // Always stop the timer, even if cancelRecording throws
      _stopDurationTimer();
    }
  }

  /// Get the current streaming transcript
  String getStreamingTranscript() {
    return _service?.getStreamingTranscript() ?? '';
  }

  /// Get confirmed segments
  List<String> getConfirmedSegments() {
    return _service?.confirmedSegments ?? [];
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.isRecording && state.recordingStartTime != null) {
        state = state.copyWith(
          recordingDuration: DateTime.now().difference(state.recordingStartTime!),
        );
      }
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  @override
  void dispose() {
    _stopDurationTimer();
    super.dispose();
  }
}

/// State for streaming recording control
class StreamingRecordingState {
  final bool isRecording;
  final DateTime? recordingStartTime;
  final Duration recordingDuration;

  const StreamingRecordingState({
    this.isRecording = false,
    this.recordingStartTime,
    this.recordingDuration = Duration.zero,
  });

  StreamingRecordingState copyWith({
    bool? isRecording,
    DateTime? recordingStartTime,
    Duration? recordingDuration,
  }) {
    return StreamingRecordingState(
      isRecording: isRecording ?? this.isRecording,
      recordingStartTime: recordingStartTime ?? this.recordingStartTime,
      recordingDuration: recordingDuration ?? this.recordingDuration,
    );
  }

  /// Format duration as MM:SS
  String get durationText {
    final minutes = recordingDuration.inMinutes;
    final seconds = recordingDuration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Provider for streaming recording control
final streamingRecordingProvider =
    StateNotifierProvider<StreamingRecordingNotifier, StreamingRecordingState>((ref) {
  return StreamingRecordingNotifier(ref);
});

/// Provider to get the current transcription service
/// Exposes convenient methods for getting transcript text
final transcriptionTextProvider = Provider<String>((ref) {
  final streamingState = ref.watch(streamingTranscriptionProvider);

  return streamingState.when(
    data: (state) => state.displayText,
    loading: () => '',
    error: (e, st) => '',
  );
});
