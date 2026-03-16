import 'package:flutter/foundation.dart';
import 'journal_entry.dart';

/// Transcription status for voice entries
enum TranscriptionStatus {
  /// Not yet transcribed
  pending,

  /// Currently being transcribed (local)
  transcribing,

  /// Server is processing (transcription + cleanup pipeline running)
  processing,

  /// Raw transcription ready, LLM cleanup still running
  transcribed,

  /// Successfully transcribed (and cleaned up if applicable)
  complete,

  /// Transcription failed
  failed,
}

/// Cleanup status for voice entries — whether LLM post-processing ran
enum CleanupStatus {
  /// Cleanup ran successfully and wrote cleaned text
  completed,

  /// Cleanup was skipped (e.g. no OAuth token)
  skipped,

  /// Cleanup attempted but failed
  failed,
}

/// Rich metadata for a journal entry stored in frontmatter.
///
/// This provides additional information beyond what's in the markdown body,
/// such as audio paths, duration, and transcription status.
@immutable
class EntryMetadata {
  /// Entry type (voice, text, linked, photo, handwriting)
  final JournalEntryType type;

  /// Audio file path (relative to vault), if voice entry
  final String? audioPath;

  /// Image file path (relative to vault), if photo/handwriting entry
  final String? imagePath;

  /// Duration in seconds, if voice entry
  final int? durationSeconds;

  /// Transcription status for voice entries
  final TranscriptionStatus? transcriptionStatus;

  /// Time the entry was created (HH:MM format)
  final String? createdTime;

  /// Whether handwriting entry has lined paper background
  final bool? linedBackground;

  /// Tags for organizing entries (e.g., "recipe", "work", "urgent")
  final List<String>? tags;

  const EntryMetadata({
    required this.type,
    this.audioPath,
    this.imagePath,
    this.durationSeconds,
    this.transcriptionStatus,
    this.createdTime,
    this.linedBackground,
    this.tags,
  });

  /// Create from a simple audio path (legacy format compatibility)
  factory EntryMetadata.fromAudioPath(String audioPath, {List<String>? tags}) {
    return EntryMetadata(
      type: JournalEntryType.voice,
      audioPath: audioPath,
      transcriptionStatus: TranscriptionStatus.complete,
      tags: tags,
    );
  }

  /// Create for a new voice entry
  factory EntryMetadata.voice({
    required String audioPath,
    required int durationSeconds,
    required String createdTime,
    bool hasPendingTranscription = false,
    List<String>? tags,
  }) {
    return EntryMetadata(
      type: JournalEntryType.voice,
      audioPath: audioPath,
      durationSeconds: durationSeconds,
      createdTime: createdTime,
      transcriptionStatus: hasPendingTranscription
          ? TranscriptionStatus.pending
          : TranscriptionStatus.complete,
      tags: tags,
    );
  }

  /// Create for a text entry
  factory EntryMetadata.text({String? createdTime, List<String>? tags}) {
    return EntryMetadata(
      type: JournalEntryType.text,
      createdTime: createdTime,
      tags: tags,
    );
  }

  /// Create for a photo entry
  factory EntryMetadata.photo({
    required String imagePath,
    required String createdTime,
    List<String>? tags,
  }) {
    return EntryMetadata(
      type: JournalEntryType.photo,
      imagePath: imagePath,
      createdTime: createdTime,
      tags: tags,
    );
  }

  /// Create for a handwriting entry
  factory EntryMetadata.handwriting({
    required String imagePath,
    required String createdTime,
    bool linedBackground = false,
    List<String>? tags,
  }) {
    return EntryMetadata(
      type: JournalEntryType.handwriting,
      imagePath: imagePath,
      createdTime: createdTime,
      linedBackground: linedBackground,
      tags: tags,
    );
  }

  /// Parse from YAML map
  factory EntryMetadata.fromYaml(Map<dynamic, dynamic> yaml) {
    // Handle simple string value (legacy format: just audio path)
    final typeStr = yaml['type'] as String?;
    final type = typeStr != null
        ? JournalEntryType.values.firstWhere(
            (t) => t.name == typeStr,
            orElse: () => JournalEntryType.text,
          )
        : JournalEntryType.voice; // Default to voice for legacy entries

    final statusStr = yaml['status'] as String?;
    TranscriptionStatus? status;
    if (statusStr != null) {
      status = TranscriptionStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => TranscriptionStatus.complete,
      );
    }

    // Parse tags from YAML (could be a list or null)
    List<String>? tags;
    final tagsValue = yaml['tags'];
    if (tagsValue != null) {
      if (tagsValue is List) {
        tags = List<String>.from(tagsValue);
      }
    }

    return EntryMetadata(
      type: type,
      audioPath: yaml['audio'] as String?,
      imagePath: yaml['image'] as String?,
      durationSeconds: yaml['duration'] as int?,
      transcriptionStatus: status,
      createdTime: yaml['created'] as String?,
      linedBackground: yaml['lined_background'] as bool?,
      tags: tags,
    );
  }

  /// Convert to YAML map for serialization
  Map<String, dynamic> toYaml() {
    final map = <String, dynamic>{
      'type': type.name,
    };

    if (audioPath != null) {
      map['audio'] = audioPath;
    }
    if (imagePath != null) {
      map['image'] = imagePath;
    }
    if (durationSeconds != null) {
      map['duration'] = durationSeconds;
    }
    if (transcriptionStatus != null) {
      map['status'] = transcriptionStatus!.name;
    }
    if (createdTime != null) {
      map['created'] = createdTime;
    }
    if (linedBackground != null) {
      map['lined_background'] = linedBackground;
    }
    if (tags != null && tags!.isNotEmpty) {
      map['tags'] = tags;
    }

    return map;
  }

  /// Create a copy with updated transcription status
  EntryMetadata copyWithStatus(TranscriptionStatus status) {
    return EntryMetadata(
      type: type,
      audioPath: audioPath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      transcriptionStatus: status,
      createdTime: createdTime,
      linedBackground: linedBackground,
    );
  }

  /// Create a copy with updated fields
  EntryMetadata copyWith({
    JournalEntryType? type,
    String? audioPath,
    String? imagePath,
    int? durationSeconds,
    TranscriptionStatus? transcriptionStatus,
    String? createdTime,
    bool? linedBackground,
    List<String>? tags,
  }) {
    return EntryMetadata(
      type: type ?? this.type,
      audioPath: audioPath ?? this.audioPath,
      imagePath: imagePath ?? this.imagePath,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      transcriptionStatus: transcriptionStatus ?? this.transcriptionStatus,
      createdTime: createdTime ?? this.createdTime,
      linedBackground: linedBackground ?? this.linedBackground,
      tags: tags ?? this.tags,
    );
  }

  @override
  String toString() =>
      'EntryMetadata(type: $type, audio: $audioPath, image: $imagePath, duration: $durationSeconds, status: $transcriptionStatus, tags: $tags)';
}
