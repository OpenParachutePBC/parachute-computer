/// Represents a speaker segment with timing information
/// Used for speaker diarization results
class SpeakerSegment {
  final String speakerId; // e.g., "SPEAKER_00", "SPEAKER_01"
  final double startTimeSeconds;
  final double endTimeSeconds;

  SpeakerSegment({
    required this.speakerId,
    required this.startTimeSeconds,
    required this.endTimeSeconds,
  }) : assert(startTimeSeconds >= 0, 'Start time must be non-negative'),
       assert(
         endTimeSeconds >= startTimeSeconds,
         'End time must be >= start time',
       );

  double get durationSeconds => endTimeSeconds - startTimeSeconds;

  Map<String, dynamic> toJson() => {
    'speakerId': speakerId,
    'startTimeSeconds': startTimeSeconds,
    'endTimeSeconds': endTimeSeconds,
  };

  factory SpeakerSegment.fromJson(Map<String, dynamic> json) => SpeakerSegment(
    speakerId: json['speakerId'] as String,
    startTimeSeconds: (json['startTimeSeconds'] as num).toDouble(),
    endTimeSeconds: (json['endTimeSeconds'] as num).toDouble(),
  );

  /// Format time as MM:SS
  String _formatTime(double seconds) {
    final minutes = seconds ~/ 60;
    final secs = (seconds % 60).floor();
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String get formattedTimeRange =>
      '${_formatTime(startTimeSeconds)} - ${_formatTime(endTimeSeconds)}';

  /// Get display name for speaker (e.g., "Speaker 1" from "SPEAKER_00")
  String get displayName {
    // Extract number from SPEAKER_XX format
    final match = RegExp(r'SPEAKER_(\d+)').firstMatch(speakerId);
    if (match != null) {
      final num = int.parse(match.group(1)!) + 1; // 0-indexed to 1-indexed
      return 'Speaker $num';
    }
    return speakerId;
  }

  @override
  String toString() =>
      'SpeakerSegment($speakerId: $formattedTimeRange [${durationSeconds.toStringAsFixed(1)}s])';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpeakerSegment &&
          runtimeType == other.runtimeType &&
          speakerId == other.speakerId &&
          startTimeSeconds == other.startTimeSeconds &&
          endTimeSeconds == other.endTimeSeconds;

  @override
  int get hashCode =>
      speakerId.hashCode ^ startTimeSeconds.hashCode ^ endTimeSeconds.hashCode;
}
