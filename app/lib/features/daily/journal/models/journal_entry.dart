import 'package:flutter/foundation.dart';
import 'entry_metadata.dart' show CleanupStatus, TranscriptionStatus;

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

  /// Whether this entry is queued for upload (written offline, not yet on server)
  final bool isPending;

  /// Whether this entry was edited locally and the edit hasn't synced yet
  final bool hasPendingEdit;

  /// Transcription status from the server pipeline.
  /// Null for locally-created entries. Lets the UI distinguish processing (no text) from
  /// transcribed (raw text visible, cleanup running).
  final TranscriptionStatus? serverTranscriptionStatus;

  /// Cleanup status from the server pipeline.
  /// Null means cleanup never ran (pre-pipeline entries).
  final CleanupStatus? cleanupStatus;

  /// Tags for organizing entries (e.g., "recipe", "work", "urgent")
  final List<String>? tags;

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
    this.isPending = false,
    this.hasPendingEdit = false,
    this.serverTranscriptionStatus,
    this.cleanupStatus,
    this.tags,
  }) : _isPendingTranscription = isPendingTranscription;

  /// Whether this entry has an associated audio file
  bool get hasAudio => audioPath != null && audioPath!.isNotEmpty;

  /// Whether this entry has an associated image file
  bool get hasImage => imagePath != null;

  /// Whether this entry links to a separate file
  bool get isLinked => linkedFilePath != null;

  /// Whether this entry has a pending transcription
  /// Uses explicit flag if set, otherwise computes from content
  bool get isPendingTranscription =>
      _isPendingTranscription ||
      (type == JournalEntryType.voice && hasAudio && (content.isEmpty || content == '*(Transcribing...)*'));

  /// Whether the server is still processing this entry (transcription or cleanup in progress)
  bool get isServerProcessing =>
      serverTranscriptionStatus == TranscriptionStatus.processing ||
      serverTranscriptionStatus == TranscriptionStatus.transcribed;

  /// Whether the server has raw text ready but cleanup is still running
  bool get isCleanupInProgress =>
      serverTranscriptionStatus == TranscriptionStatus.transcribed;

  /// Whether server transcription failed
  bool get isTranscriptionFailed =>
      serverTranscriptionStatus == TranscriptionStatus.failed;

  /// Whether this entry has been cleaned up by the LLM
  bool get isCleanedUp => cleanupStatus == CleanupStatus.completed;

  /// Whether this voice entry needs cleanup (never ran, skipped, or failed)
  bool get needsCleanup =>
      type == JournalEntryType.voice &&
      !isServerProcessing &&
      cleanupStatus != CleanupStatus.completed;

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

  /// Create from server API JSON response
  ///
  /// The server returns entries with `id`, `created_at`, `content`, and `metadata`.
  /// The `metadata` dict carries type-specific fields stored in frontmatter.
  factory JournalEntry.fromServerJson(Map<String, dynamic> json) {
    final meta = (json['metadata'] as Map<String, dynamic>?) ?? {};
    final typeStr = meta['type'] as String? ?? 'text';
    final statusStr = meta['transcription_status'] as String?;
    final transcriptionStatus = _parseTranscriptionStatus(statusStr);
    final isPending = transcriptionStatus == TranscriptionStatus.processing ||
        transcriptionStatus == TranscriptionStatus.transcribed;
    final cleanupStr = meta['cleanup_status'] as String?;
    final cleanupStatus = _parseCleanupStatus(cleanupStr);

    // Parse tags from metadata (could be a list or null)
    List<String>? tags;
    final tagsValue = meta['tags'];
    if (tagsValue != null) {
      if (tagsValue is List) {
        tags = List<String>.from(tagsValue);
      }
    }

    return JournalEntry(
      id: json['id'] as String,
      title: meta['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      type: parseType(typeStr),
      createdAt: parseDateTime(json['created_at'] as String?),
      audioPath: meta['audio_path'] as String?,
      imagePath: meta['image_path'] as String?,
      durationSeconds: switch (meta['duration_seconds']) {
        final int v => v,
        final double v => v.toInt(),
        final String v => int.tryParse(v),
        _ => null,
      },
      isPendingTranscription: isPending,
      serverTranscriptionStatus: transcriptionStatus,
      cleanupStatus: cleanupStatus,
      tags: tags,
    );
  }

  /// Parse a server transcription_status string into a [TranscriptionStatus].
  static TranscriptionStatus? _parseTranscriptionStatus(String? status) {
    if (status == null) return null;
    return TranscriptionStatus.values.cast<TranscriptionStatus?>().firstWhere(
      (s) => s?.name == status,
      orElse: () => null,
    );
  }

  /// Parse a server cleanup_status string into a [CleanupStatus].
  static CleanupStatus? _parseCleanupStatus(String? status) {
    if (status == null) return null;
    return CleanupStatus.values.cast<CleanupStatus?>().firstWhere(
      (s) => s?.name == status,
      orElse: () => null,
    );
  }

  static JournalEntryType parseType(String typeStr) {
    switch (typeStr) {
      case 'voice':
      case 'audio': return JournalEntryType.voice;
      case 'photo': return JournalEntryType.photo;
      case 'handwriting': return JournalEntryType.handwriting;
      case 'linked': return JournalEntryType.linked;
      default: return JournalEntryType.text;
    }
  }

  static DateTime parseDateTime(String? iso) {
    if (iso == null || iso.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(iso).toLocal();
    } catch (_) {
      return DateTime.now();
    }
  }

  /// Create a pending entry (written offline, not yet on server)
  factory JournalEntry.pending({
    required String localId,
    required String content,
    JournalEntryType type = JournalEntryType.text,
    String? title,
    String? audioPath,
    String? imagePath,
    int? durationSeconds,
    DateTime? createdAt,
  }) {
    return JournalEntry(
      id: localId,
      title: title ?? '',
      content: content,
      type: type,
      createdAt: createdAt ?? DateTime.now(),
      audioPath: audioPath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      isPending: true,
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
    bool? isPending,
    bool? hasPendingEdit,
    TranscriptionStatus? serverTranscriptionStatus,
    CleanupStatus? cleanupStatus,
    List<String>? tags,
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
      isPending: isPending ?? this.isPending,
      hasPendingEdit: hasPendingEdit ?? this.hasPendingEdit,
      serverTranscriptionStatus: serverTranscriptionStatus ?? this.serverTranscriptionStatus,
      cleanupStatus: cleanupStatus ?? this.cleanupStatus,
      tags: tags ?? this.tags,
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
