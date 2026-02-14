import 'transcription_segment.dart';

/// Persisted segment for background recovery
/// Stored in JSON file to survive app restarts
class PersistedSegment {
  final int index;
  final String audioFilePath;
  final int startOffsetBytes; // Byte offset in audio file (after WAV header)
  final int durationSamples; // Number of samples
  final TranscriptionSegmentStatus status;
  final String? transcribedText;
  final DateTime createdAt;
  final DateTime? completedAt;

  PersistedSegment({
    required this.index,
    required this.audioFilePath,
    required this.startOffsetBytes,
    required this.durationSamples,
    required this.status,
    this.transcribedText,
    required this.createdAt,
    this.completedAt,
  });

  Map<String, dynamic> toJson() => {
    'index': index,
    'audioFilePath': audioFilePath,
    'startOffsetBytes': startOffsetBytes,
    'durationSamples': durationSamples,
    'status': status.name,
    'transcribedText': transcribedText,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
  };

  factory PersistedSegment.fromJson(Map<String, dynamic> json) {
    return PersistedSegment(
      index: json['index'] as int,
      audioFilePath: json['audioFilePath'] as String,
      startOffsetBytes: json['startOffsetBytes'] as int,
      durationSamples: json['durationSamples'] as int,
      status: TranscriptionSegmentStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TranscriptionSegmentStatus.pending,
      ),
      transcribedText: json['transcribedText'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
    );
  }

  PersistedSegment copyWith({
    int? index,
    String? audioFilePath,
    int? startOffsetBytes,
    int? durationSamples,
    TranscriptionSegmentStatus? status,
    String? transcribedText,
    DateTime? createdAt,
    DateTime? completedAt,
  }) {
    return PersistedSegment(
      index: index ?? this.index,
      audioFilePath: audioFilePath ?? this.audioFilePath,
      startOffsetBytes: startOffsetBytes ?? this.startOffsetBytes,
      durationSamples: durationSamples ?? this.durationSamples,
      status: status ?? this.status,
      transcribedText: transcribedText ?? this.transcribedText,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}
