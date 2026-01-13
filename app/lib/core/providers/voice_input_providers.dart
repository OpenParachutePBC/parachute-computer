import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/voice_input_service.dart';
import '../services/transcription/transcription_service_adapter.dart';

/// Voice input state enum
enum VoiceInputState {
  idle,
  recording,
  transcribing,
  processing,
  error,
}

/// Provider for voice input service
final voiceInputServiceProvider = Provider<VoiceInputService>((ref) {
  final service = VoiceInputService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Transcription service singleton
final transcriptionServiceProvider = Provider<TranscriptionServiceAdapter>((ref) {
  final service = TranscriptionServiceAdapter();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for current voice input state
final voiceInputCurrentStateProvider = StateProvider<VoiceInputState>((ref) {
  return VoiceInputState.idle;
});

/// Provider for voice input duration
final voiceInputDurationProvider = StateProvider<AsyncValue<Duration>>((ref) {
  return const AsyncValue.data(Duration.zero);
});

/// Provider for voice input error
final voiceInputErrorProvider = StateProvider<AsyncValue<String>>((ref) {
  return const AsyncValue.data('');
});

/// Whether transcription models are ready
final transcriptionReadyProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(transcriptionServiceProvider);
  return await service.isReady();
});
