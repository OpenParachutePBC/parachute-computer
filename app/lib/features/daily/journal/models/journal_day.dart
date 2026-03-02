import 'package:flutter/foundation.dart';
import 'journal_entry.dart';
import 'entry_metadata.dart';

/// A full day's journal containing multiple entries.
///
/// Corresponds to a single markdown file in the Daily/ folder.
/// File naming: `Daily/2025-12-14.md`
@immutable
class JournalDay {
  /// The date this journal represents
  final DateTime date;

  /// All entries for this day, in chronological order
  final List<JournalEntry> entries;

  /// Rich metadata for entries from frontmatter (para ID -> metadata)
  final Map<String, EntryMetadata> entryMetadata;

  /// Path to the journal file (relative to vault)
  final String filePath;

  const JournalDay({
    required this.date,
    required this.entries,
    required this.entryMetadata,
    required this.filePath,
  });

  /// Legacy accessor for backward compatibility
  /// Returns a map of para ID -> audio path (for entries that have audio)
  Map<String, String> get assets {
    final result = <String, String>{};
    for (final entry in entryMetadata.entries) {
      if (entry.value.audioPath != null) {
        result[entry.key] = entry.value.audioPath!;
      }
    }
    return result;
  }

  /// Create an empty journal for a date
  factory JournalDay.empty(DateTime date) {
    return JournalDay(
      date: DateTime(date.year, date.month, date.day),
      entries: const [],
      entryMetadata: const {},
      filePath: '',
    );
  }

  /// Create from a list of server entries (API-backed)
  factory JournalDay.fromEntries(DateTime date, List<JournalEntry> entries) {
    return JournalDay(
      date: DateTime(date.year, date.month, date.day),
      entries: entries,
      entryMetadata: const {},
      filePath: '',
    );
  }

  /// Whether this journal has any entries
  bool get isEmpty => entries.isEmpty;

  /// Whether this journal has entries
  bool get isNotEmpty => entries.isNotEmpty;

  /// Number of entries
  int get entryCount => entries.length;

  /// Date formatted as YYYY-MM-DD
  String get dateString => _formatDate(date);

  /// Date formatted for display (e.g., "Saturday, December 14, 2025")
  String get displayDate {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];

    final dayName = days[date.weekday - 1];
    final monthName = months[date.month - 1];
    return '$dayName, $monthName ${date.day}, ${date.year}';
  }

  /// Whether this is today's journal
  bool get isToday {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  /// Get entry by para ID
  JournalEntry? getEntry(String id) {
    try {
      return entries.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get audio path for an entry
  String? getAudioPath(String entryId) => assets[entryId];

  /// Get image path for an entry
  String? getImagePath(String entryId) {
    final metadata = entryMetadata[entryId];
    return metadata?.imagePath;
  }

  /// Get all entries with pending transcriptions
  List<JournalEntry> get pendingTranscriptions =>
      entries.where((e) => e.isPendingTranscription).toList();

  /// Whether this journal has any pending transcriptions
  bool get hasPendingTranscriptions =>
      entries.any((e) => e.isPendingTranscription);

  /// Create a copy with a new entry added
  JournalDay addEntry(JournalEntry entry, {EntryMetadata? metadata}) {
    final newEntries = [...entries, entry];
    final newMetadata = Map<String, EntryMetadata>.from(entryMetadata);

    if (metadata != null) {
      newMetadata[entry.id] = metadata;
    }

    return JournalDay(
      date: date,
      entries: newEntries,
      entryMetadata: newMetadata,
      filePath: filePath,
    );
  }

  /// Create a copy with an entry updated
  JournalDay updateEntry(JournalEntry entry, {EntryMetadata? metadata}) {
    final newEntries = entries.map((e) => e.id == entry.id ? entry : e).toList();
    final newMetadata = Map<String, EntryMetadata>.from(entryMetadata);

    if (metadata != null) {
      newMetadata[entry.id] = metadata;
    }

    return JournalDay(
      date: date,
      entries: newEntries,
      entryMetadata: newMetadata,
      filePath: filePath,
    );
  }

  /// Create a copy with an entry removed
  JournalDay removeEntry(String id) {
    final newEntries = entries.where((e) => e.id != id).toList();
    final newMetadata = Map<String, EntryMetadata>.from(entryMetadata)..remove(id);

    return JournalDay(
      date: date,
      entries: newEntries,
      entryMetadata: newMetadata,
      filePath: filePath,
    );
  }

  /// Create a copy with updated fields
  JournalDay copyWith({
    DateTime? date,
    List<JournalEntry>? entries,
    Map<String, EntryMetadata>? entryMetadata,
    String? filePath,
  }) {
    return JournalDay(
      date: date ?? this.date,
      entries: entries ?? this.entries,
      entryMetadata: entryMetadata ?? this.entryMetadata,
      filePath: filePath ?? this.filePath,
    );
  }

  static String _formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is JournalDay && other.dateString == dateString;
  }

  @override
  int get hashCode => dateString.hashCode;

  @override
  String toString() => 'JournalDay($dateString, ${entries.length} entries)';
}
