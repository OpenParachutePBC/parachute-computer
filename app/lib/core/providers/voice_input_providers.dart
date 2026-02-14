import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/transcription/transcription_service_adapter.dart';

/// Transcription service singleton
final transcriptionServiceProvider = Provider<TranscriptionServiceAdapter>((ref) {
  final service = TranscriptionServiceAdapter();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Whether transcription models are ready
final transcriptionReadyProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(transcriptionServiceProvider);
  return await service.isReady();
});
