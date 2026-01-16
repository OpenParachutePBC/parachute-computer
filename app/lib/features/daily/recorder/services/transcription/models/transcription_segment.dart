/// Status of a transcription segment
enum TranscriptionSegmentStatus {
  pending, // Waiting to be transcribed
  processing, // Currently being transcribed
  completed, // Transcription done
  failed, // Transcription error
  interrupted, // Was processing when app closed (for recovery)
}

/// Represents a transcribed segment (auto-detected via VAD)
class TranscriptionSegment {
  final int index; // Segment number (1, 2, 3, ...)
  final String text;
  final TranscriptionSegmentStatus status;
  final DateTime timestamp;
  final Duration duration; // Audio duration of this segment

  TranscriptionSegment({
    required this.index,
    required this.text,
    required this.status,
    required this.timestamp,
    required this.duration,
  });

  TranscriptionSegment copyWith({
    int? index,
    String? text,
    TranscriptionSegmentStatus? status,
    DateTime? timestamp,
    Duration? duration,
  }) {
    return TranscriptionSegment(
      index: index ?? this.index,
      text: text ?? this.text,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      duration: duration ?? this.duration,
    );
  }
}
