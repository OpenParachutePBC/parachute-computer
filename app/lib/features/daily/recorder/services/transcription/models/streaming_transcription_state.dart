/// Transcription model status
enum TranscriptionModelStatus {
  notInitialized, // Model not yet initialized
  initializing, // Model is loading
  ready, // Model ready for transcription
  error, // Initialization failed
}

/// Streaming transcription state for UI
class StreamingTranscriptionState {
  final String confirmedText;   // Stable across 2+ iterations (locked, won't change)
  final String tentativeText;   // Stable for 1 iteration (likely stable)
  final String interimText;     // Current transcription suffix (may change)
  final List<String> confirmedSegments; // For final transcript assembly
  final bool isRecording;
  final bool isProcessing;
  final Duration recordingDuration;
  final double vadLevel; // 0.0 to 1.0 speech energy level
  final TranscriptionModelStatus modelStatus; // Track model initialization

  const StreamingTranscriptionState({
    this.confirmedText = '',
    this.tentativeText = '',
    this.interimText = '',
    this.confirmedSegments = const [],
    this.isRecording = false,
    this.isProcessing = false,
    this.recordingDuration = Duration.zero,
    this.vadLevel = 0.0,
    this.modelStatus = TranscriptionModelStatus.notInitialized,
  });

  StreamingTranscriptionState copyWith({
    String? confirmedText,
    String? tentativeText,
    String? interimText,
    List<String>? confirmedSegments,
    bool? isRecording,
    bool? isProcessing,
    Duration? recordingDuration,
    double? vadLevel,
    TranscriptionModelStatus? modelStatus,
  }) {
    return StreamingTranscriptionState(
      confirmedText: confirmedText ?? this.confirmedText,
      tentativeText: tentativeText ?? this.tentativeText,
      interimText: interimText ?? this.interimText,
      confirmedSegments: confirmedSegments ?? this.confirmedSegments,
      isRecording: isRecording ?? this.isRecording,
      isProcessing: isProcessing ?? this.isProcessing,
      recordingDuration: recordingDuration ?? this.recordingDuration,
      vadLevel: vadLevel ?? this.vadLevel,
      modelStatus: modelStatus ?? this.modelStatus,
    );
  }

  /// Get all text for display
  /// Shows only confirmed/final text from VAD-detected segments.
  /// No interim text during speech - simpler, no duplicates.
  String get displayText {
    return confirmedSegments.join(' ').trim();
  }
}
