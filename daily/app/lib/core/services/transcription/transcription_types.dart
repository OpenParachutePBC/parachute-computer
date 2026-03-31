/// Transcription result with optional word-level timestamps
class AdapterTranscriptionResult {
  final String text;
  final List<String>? tokens;
  final List<double>? timestamps;

  AdapterTranscriptionResult({
    required this.text,
    this.tokens,
    this.timestamps,
  });

  bool get hasWordTimestamps =>
      tokens != null &&
      timestamps != null &&
      tokens!.length == timestamps!.length;
}

/// Transcription progress data
class TranscriptionProgress {
  final double progress;
  final String status;
  final bool isComplete;

  TranscriptionProgress({
    required this.progress,
    required this.status,
    this.isComplete = false,
  });
}

/// Generic transcription exception
class TranscriptionException implements Exception {
  final String message;

  TranscriptionException(this.message);

  @override
  String toString() => message;
}
