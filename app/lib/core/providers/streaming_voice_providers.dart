import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/streaming_voice_service.dart';
import 'voice_input_providers.dart'; // Reuse transcriptionServiceProvider

/// Streaming voice service singleton
final streamingVoiceServiceProvider = Provider<StreamingVoiceService>((ref) {
  final transcriptionService = ref.watch(transcriptionServiceProvider);
  final service = StreamingVoiceService(transcriptionService);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Streaming transcription state provider
final streamingTranscriptionStateProvider = StreamProvider<StreamingTranscriptionState>((ref) {
  final service = ref.watch(streamingVoiceServiceProvider);
  return service.streamingStateStream;
});

/// Current streaming state (for synchronous access)
final streamingVoiceCurrentStateProvider = Provider<StreamingTranscriptionState>((ref) {
  return ref.watch(streamingTranscriptionStateProvider).when(
    data: (state) => state,
    loading: () => const StreamingTranscriptionState(),
    error: (_, __) => const StreamingTranscriptionState(),
  );
});

/// Whether streaming recording is active
final isStreamingRecordingProvider = Provider<bool>((ref) {
  final state = ref.watch(streamingVoiceCurrentStateProvider);
  return state.isRecording;
});

/// Interim text stream
final streamingInterimTextProvider = StreamProvider<String>((ref) {
  final service = ref.watch(streamingVoiceServiceProvider);
  return service.interimTextStream;
});

/// Streaming recording state notifier for UI control
class StreamingRecordingNotifier extends StateNotifier<bool> {
  final StreamingVoiceService _service;

  StreamingRecordingNotifier(this._service) : super(false);

  Future<bool> startRecording() async {
    final success = await _service.startRecording();
    state = success;
    return success;
  }

  Future<String?> stopRecording() async {
    final path = await _service.stopRecording();
    state = false;
    return path;
  }

  Future<void> cancelRecording() async {
    await _service.cancelRecording();
    state = false;
  }

  String getStreamingTranscript() {
    return _service.getStreamingTranscript();
  }
}

/// Streaming recording notifier provider
final streamingRecordingNotifierProvider = StateNotifierProvider<StreamingRecordingNotifier, bool>((ref) {
  final service = ref.watch(streamingVoiceServiceProvider);
  return StreamingRecordingNotifier(service);
});
