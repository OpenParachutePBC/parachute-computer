import 'package:flutter/foundation.dart';

/// The type of a journal entry based on how it was created.
enum JournalEntryType {
  /// Typed text entry
  text,

  /// Voice recording with transcript
  voice,

  /// Link to a longer recording in a separate file
  linked,

  /// Photo entry (camera or gallery)
  photo,

  /// Handwriting canvas entry
  handwriting,
}

/// A single entry in a journal day.
///
/// Each entry corresponds to an H1 section in the journal markdown file.
/// Format: `# para:abc123 Title here`
@immutable
class JournalEntry {
  /// Unique 6-character para ID
  final String id;

  /// Entry title (displayed after the para ID)
  final String title;

  /// Main content (transcript or typed text)
  final String content;

  /// Type of entry
  final JournalEntryType type;

  /// Timestamp when the entry was created
  final DateTime createdAt;

  /// Path to linked audio file (relative to vault), if any
  final String? audioPath;

  /// Path to linked full transcript file, if this is a linked entry
  final String? linkedFilePath;

  /// Path to image file (relative to vault), for photo/handwriting entries
  final String? imagePath;

  /// Duration of the audio in seconds, if voice entry
  final int? durationSeconds;

  /// Whether this entry is plain markdown (no para:ID)
  /// Used to preserve formatting when re-serializing imported content.
  final bool isPlainMarkdown;

  /// Whether this entry has a pending transcription
  /// Set explicitly when creating entry with pending transcription status.
  final bool _isPendingTranscription;

  const JournalEntry({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.createdAt,
    this.audioPath,
    this.linkedFilePath,
    this.imagePath,
    this.durationSeconds,
    this.isPlainMarkdown = false,
    bool isPendingTranscription = false,
  }) : _isPendingTranscription = isPendingTranscription;

  /// Whether this entry has an associated audio file
  bool get hasAudio => audioPath != null;

  /// Whether this entry has an associated image file
  bool get hasImage => imagePath != null;

  /// Whether this entry links to a separate file
  bool get isLinked => linkedFilePath != null;

  /// Whether this entry has a pending transcription
  /// Uses explicit flag if set, otherwise computes from content
  bool get isPendingTranscription =>
      _isPendingTranscription ||
      (type == JournalEntryType.voice && hasAudio && (content.isEmpty || content == '*(Transcribing...)*'));

  /// Format the H1 line for this entry
  String get h1Line => '# para:$id $title';

  /// Create a text-only entry
  factory JournalEntry.text({
    required String id,
    required String title,
    required String content,
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: JournalEntryType.text,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Create a voice entry with inline transcript
  factory JournalEntry.voice({
    required String id,
    required String title,
    required String content,
    required String audioPath,
    required int durationSeconds,
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: JournalEntryType.voice,
      createdAt: createdAt ?? DateTime.now(),
      audioPath: audioPath,
      durationSeconds: durationSeconds,
    );
  }

  /// Create a linked entry that points to a separate file
  factory JournalEntry.linked({
    required String id,
    required String title,
    required String linkedFilePath,
    String? audioPath,
    int? durationSeconds,
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: id,
      title: title,
      content: '', // Content lives in the linked file
      type: JournalEntryType.linked,
      createdAt: createdAt ?? DateTime.now(),
      linkedFilePath: linkedFilePath,
      audioPath: audioPath,
      durationSeconds: durationSeconds,
    );
  }

  /// Create a photo entry (camera or gallery)
  factory JournalEntry.photo({
    required String id,
    required String title,
    required String imagePath,
    String content = '', // OCR-extracted text or description
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: JournalEntryType.photo,
      createdAt: createdAt ?? DateTime.now(),
      imagePath: imagePath,
    );
  }

  /// Create a handwriting canvas entry
  factory JournalEntry.handwriting({
    required String id,
    required String title,
    required String imagePath,
    String content = '', // OCR-extracted text
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: JournalEntryType.handwriting,
      createdAt: createdAt ?? DateTime.now(),
      imagePath: imagePath,
    );
  }

  /// Create a copy with updated fields
  JournalEntry copyWith({
    String? id,
    String? title,
    String? content,
    JournalEntryType? type,
    DateTime? createdAt,
    String? audioPath,
    String? linkedFilePath,
    String? imagePath,
    int? durationSeconds,
    bool? isPlainMarkdown,
    bool? isPendingTranscription,
  }) {
    return JournalEntry(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      type: type ?? this.type,
      createdAt: createdAt ?? this.createdAt,
      audioPath: audioPath ?? this.audioPath,
      linkedFilePath: linkedFilePath ?? this.linkedFilePath,
      imagePath: imagePath ?? this.imagePath,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isPlainMarkdown: isPlainMarkdown ?? this.isPlainMarkdown,
      isPendingTranscription: isPendingTranscription ?? _isPendingTranscription,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is JournalEntry && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'JournalEntry(id: $id, title: $title, type: $type)';
}
