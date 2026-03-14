import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:parachute/core/services/transcription/transcription_service_adapter.dart';

/// Post-hoc transcription progress states
sealed class PostHocProgress {
  const PostHocProgress();
}

class PostHocIdle extends PostHocProgress {
  const PostHocIdle();
}

class PostHocInProgress extends PostHocProgress {
  final double progress; // 0.0 - 1.0
  final String status;

  const PostHocInProgress({required this.progress, required this.status});
}

class PostHocComplete extends PostHocProgress {
  final String transcription;

  const PostHocComplete({required this.transcription});
}

class PostHocFailed extends PostHocProgress {
  final String error;

  const PostHocFailed({required this.error});
}

/// Pure transcription service for post-hoc batch processing
///
/// Thin wrapper: accepts a WAV path, calls TranscriptionServiceAdapter,
/// emits PostHocProgress via stream. Does NOT create entries or call APIs —
/// that's the provider's job (per codebase patterns).
class PostHocTranscriptionService {
  final TranscriptionServiceAdapter _transcriptionService;
  final _progressController = StreamController<PostHocProgress>.broadcast();

  PostHocTranscriptionService({
    required TranscriptionServiceAdapter transcriptionService,
  }) : _transcriptionService = transcriptionService;

  /// Stream of transcription progress events
  Stream<PostHocProgress> get progressStream => _progressController.stream;

  /// Transcribe audio file and emit progress
  ///
  /// [audioPath] - Absolute path to WAV file (16kHz mono)
  ///
  /// Returns the transcription text on success.
  /// Throws on failure (audio preserved by caller).
  Future<String> transcribe(String audioPath) async {
    _progressController.add(
      const PostHocInProgress(progress: 0.0, status: 'Starting transcription...'),
    );

    try {
      final result = await _transcriptionService.transcribeAudio(
        audioPath,
        language: 'auto',
        onProgress: (p) {
          _progressController.add(
            PostHocInProgress(
              progress: p.progress,
              status: _statusForProgress(p.progress),
            ),
          );
        },
      );

      final transcript = result.text;

      _progressController.add(PostHocComplete(transcription: transcript));

      debugPrint(
        '[PostHocTranscription] ✅ Complete: ${transcript.length} chars',
      );

      return transcript;
    } catch (e) {
      final error = e.toString();
      _progressController.add(PostHocFailed(error: error));
      debugPrint('[PostHocTranscription] ❌ Failed: $error');
      rethrow;
    }
  }

  String _statusForProgress(double progress) {
    if (progress < 0.3) return 'Transcribing...';
    if (progress < 0.6) return 'Processing audio...';
    if (progress < 0.9) return 'Finalizing...';
    return 'Almost done...';
  }

  void dispose() {
    _progressController.close();
  }
}
