import 'package:flutter/foundation.dart';
import 'package:parachute/features/daily/recorder/services/transcription_service_adapter.dart';

/// Post-processing pipeline for recordings
///
/// Runs after recording stops:
/// 1. Transcribe audio (Parakeet v3 via FluidAudio or Sherpa-ONNX)
/// 2. Return completed recording with transcript
class RecordingPostProcessingService {
  final TranscriptionServiceAdapter _transcriptionService;

  RecordingPostProcessingService({
    required TranscriptionServiceAdapter transcriptionService,
  }) : _transcriptionService = transcriptionService;

  /// Process a recording - transcribe audio
  ///
  /// [audioPath] - Path to the WAV file
  /// [onProgress] - Optional callback for progress updates
  ///
  /// Returns the transcript
  Future<ProcessingResult> process({
    required String audioPath,
    Function(String status, double progress)? onProgress,
  }) async {
    try {
      // Step 1: Transcribe audio
      onProgress?.call('Transcribing audio...', 0.0);
      debugPrint('[PostProcessing] Step 1: Transcribing $audioPath');

      final transcriptionResult = await _transcriptionService.transcribeAudio(
        audioPath,
        language: 'auto',
        onProgress: (p) {
          onProgress?.call('Transcribing audio...', p.progress);
        },
      );

      final transcript = transcriptionResult.text;

      debugPrint(
        '[PostProcessing] ✅ Transcription complete: ${transcript.length} chars',
      );

      onProgress?.call('Complete!', 1.0);
      debugPrint('[PostProcessing] ✅ Pipeline complete');

      return ProcessingResult(transcript: transcript);
    } catch (e, stack) {
      debugPrint('[PostProcessing] ❌ Error: $e');
      debugPrint('[PostProcessing] Stack: $stack');
      rethrow;
    }
  }
}

/// Result from post-processing pipeline
class ProcessingResult {
  final String transcript;

  ProcessingResult({required this.transcript});
}
