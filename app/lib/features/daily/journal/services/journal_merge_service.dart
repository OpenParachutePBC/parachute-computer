import 'package:flutter/foundation.dart';

import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../models/entry_metadata.dart';
import 'para_id_service.dart';

/// Result of merging two journal files
class JournalMergeResult {
  /// The merged markdown content
  final String mergedContent;

  /// Entry IDs that had true conflicts (same ID, different content)
  final List<String> conflictEntryIds;

  /// Number of entries added from local that weren't on server
  final int localOnlyCount;

  /// Number of entries that were only on server (before merge)
  final int serverOnlyCount;

  JournalMergeResult({
    required this.mergedContent,
    required this.conflictEntryIds,
    required this.localOnlyCount,
    required this.serverOnlyCount,
  });

  /// Whether any true conflicts were detected
  bool get hasConflicts => conflictEntryIds.isNotEmpty;

  /// Whether the merge actually changed anything
  bool get hadChanges => localOnlyCount > 0 || serverOnlyCount > 0 || hasConflicts;
}

/// Service for merging journal files at the entry level.
///
/// This enables intelligent sync where entries from different devices
/// are combined rather than creating conflict files for the entire journal.
///
/// Merge strategy:
/// 1. Parse both files into entries by para ID
/// 2. Union all entries (server as base, add local-only)
/// 3. Detect true conflicts (same ID, different content) - local wins
/// 4. Sort by timestamp and serialize
class JournalMergeService {
  /// Merge local and server journal content for a given date.
  ///
  /// Returns merged content and list of conflicting entry IDs.
  Future<JournalMergeResult> merge({
    required String localContent,
    required String serverContent,
    required DateTime date,
  }) async {
    final localJournal = _parseJournalContent(localContent, date);
    final serverJournal = _parseJournalContent(serverContent, date);

    final mergedEntries = <String, JournalEntry>{};
    final mergedMetadata = <String, EntryMetadata>{};
    final conflictIds = <String>[];
    var localOnlyCount = 0;
    var serverOnlyCount = serverJournal.entries.length;

    // Start with server entries (base)
    for (final entry in serverJournal.entries) {
      mergedEntries[entry.id] = entry;
    }
    mergedMetadata.addAll(serverJournal.entryMetadata);

    // Merge local entries
    for (final entry in localJournal.entries) {
      if (!mergedEntries.containsKey(entry.id)) {
        // New entry from local - add it
        mergedEntries[entry.id] = entry;
        localOnlyCount++;

        // Also merge metadata
        if (localJournal.entryMetadata.containsKey(entry.id)) {
          mergedMetadata[entry.id] = localJournal.entryMetadata[entry.id]!;
        }
      } else {
        // Entry exists in both - check for conflict
        final serverEntry = mergedEntries[entry.id]!;
        if (_contentDiffers(entry, serverEntry)) {
          // True conflict - same ID, different content
          conflictIds.add(entry.id);
          // Keep LOCAL version (user's current device wins for conflicts)
          mergedEntries[entry.id] = entry;
          // Also use local metadata
          if (localJournal.entryMetadata.containsKey(entry.id)) {
            mergedMetadata[entry.id] = localJournal.entryMetadata[entry.id]!;
          }
        }
        // Adjust count - this wasn't server-only
        serverOnlyCount--;
      }
    }

    // Sort entries by title (which contains timestamp like "07:30")
    // Handle preamble specially (always first)
    final sortedEntries = mergedEntries.values.toList()
      ..sort((a, b) {
        if (a.id == 'preamble') return -1;
        if (b.id == 'preamble') return 1;
        // Sort by title (timestamp) for consistency
        return a.title.compareTo(b.title);
      });

    // Serialize merged journal
    final merged = JournalDay(
      date: date,
      entries: sortedEntries,
      entryMetadata: mergedMetadata,
      filePath: 'journals/${_formatDate(date)}.md',
    );

    final mergedContent = _serializeJournal(merged);

    debugPrint('[JournalMergeService] Merged ${merged.entries.length} entries '
        '(local-only: $localOnlyCount, server-only: $serverOnlyCount, conflicts: ${conflictIds.length})');

    return JournalMergeResult(
      mergedContent: mergedContent,
      conflictEntryIds: conflictIds,
      localOnlyCount: localOnlyCount,
      serverOnlyCount: serverOnlyCount,
    );
  }

  /// Check if two entries have meaningfully different content
  bool _contentDiffers(JournalEntry a, JournalEntry b) {
    // Normalize whitespace for comparison
    final contentA = a.content.trim();
    final contentB = b.content.trim();
    return contentA != contentB;
  }

  /// Parse journal content into a JournalDay model
  JournalDay _parseJournalContent(String content, DateTime date) {
    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    // Parse frontmatter for metadata
    Map<String, EntryMetadata> entryMetadata = {};
    if (frontmatter.isNotEmpty) {
      entryMetadata = _parseFrontmatterMetadata(frontmatter);
    }

    // Parse entries from body
    final entries = _parseEntries(body, entryMetadata);

    return JournalDay(
      date: date,
      entries: entries,
      entryMetadata: entryMetadata,
      filePath: 'journals/${_formatDate(date)}.md',
    );
  }

  /// Split content into frontmatter and body
  (String, String) _splitFrontmatter(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('---')) {
      return ('', trimmed);
    }

    final endIndex = trimmed.indexOf('---', 3);
    if (endIndex == -1) {
      return ('', trimmed);
    }

    final frontmatter = trimmed.substring(3, endIndex).trim();
    final body = trimmed.substring(endIndex + 3).trim();
    return (frontmatter, body);
  }

  /// Parse metadata from frontmatter (simplified - just extracts entries section)
  Map<String, EntryMetadata> _parseFrontmatterMetadata(String frontmatter) {
    final metadata = <String, EntryMetadata>{};
    // Simple parsing - look for entries section
    // Full YAML parsing is in JournalService; this is a simplified version for merge
    final lines = frontmatter.split('\n');

    bool inEntries = false;
    String? currentId;
    final currentFields = <String, String>{};

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed == 'entries:') {
        inEntries = true;
        continue;
      }

      if (!inEntries) continue;

      // Check for new entry ID (2 spaces indent)
      if (line.startsWith('  ') && !line.startsWith('    ') && trimmed.endsWith(':')) {
        // Save previous entry
        if (currentId != null && currentFields.isNotEmpty) {
          metadata[currentId] = _buildMetadata(currentFields);
        }
        currentId = trimmed.substring(0, trimmed.length - 1);
        currentFields.clear();
      }
      // Check for field (4 spaces indent)
      else if (line.startsWith('    ') && currentId != null) {
        final colonIndex = trimmed.indexOf(':');
        if (colonIndex > 0) {
          final key = trimmed.substring(0, colonIndex).trim();
          final value = trimmed.substring(colonIndex + 1).trim();
          currentFields[key] = value;
        }
      }
    }

    // Don't forget last entry
    if (currentId != null && currentFields.isNotEmpty) {
      metadata[currentId] = _buildMetadata(currentFields);
    }

    return metadata;
  }

  /// Build EntryMetadata from parsed fields
  EntryMetadata _buildMetadata(Map<String, String> fields) {
    final type = fields['type'] ?? 'text';
    final audioPath = fields['audio'];
    final imagePath = fields['image'];
    final durationStr = fields['duration'];
    final duration = durationStr != null ? int.tryParse(durationStr) ?? 0 : 0;
    final createdTime = fields['created'] ?? '';

    if (type == 'voice' && audioPath != null) {
      return EntryMetadata.voice(
        audioPath: audioPath,
        durationSeconds: duration,
        createdTime: createdTime,
      );
    } else if (type == 'photo' && imagePath != null) {
      return EntryMetadata.photo(
        imagePath: imagePath,
        createdTime: createdTime,
      );
    } else if (type == 'handwriting' && imagePath != null) {
      return EntryMetadata.handwriting(
        imagePath: imagePath,
        createdTime: createdTime,
      );
    }

    return EntryMetadata.text(createdTime: createdTime);
  }

  /// Parse entries from body text
  List<JournalEntry> _parseEntries(String body, Map<String, EntryMetadata> entryMetadata) {
    if (body.isEmpty) return [];

    final entries = <JournalEntry>[];
    final lines = body.split('\n');

    String? currentId;
    String? currentTitle;
    bool isPlainH1 = false;
    final contentBuffer = StringBuffer();
    int plainEntryCounter = 0;
    bool hasPreamble = false;

    for (final line in lines) {
      final trimmedLine = line.trim();

      // Check for para:ID format first
      final paraId = ParaIdService.parseFromH1(trimmedLine);

      if (paraId != null) {
        // Save previous entry if exists
        if (currentId != null) {
          entries.add(_createEntry(
            id: currentId,
            title: currentTitle ?? '',
            content: contentBuffer.toString().trim(),
            metadata: entryMetadata[currentId],
            isPlainMarkdown: isPlainH1,
          ));
        } else if (hasPreamble && contentBuffer.toString().trim().isNotEmpty) {
          entries.add(_createEntry(
            id: 'preamble',
            title: '',
            content: contentBuffer.toString().trim(),
            metadata: null,
            isPlainMarkdown: true,
          ));
        }

        // Start new para entry
        currentId = paraId;
        currentTitle = ParaIdService.parseTitleFromH1(trimmedLine);
        isPlainH1 = false;
        contentBuffer.clear();
      } else if (trimmedLine.startsWith('# ')) {
        // Plain H1 without para:ID
        if (currentId != null) {
          entries.add(_createEntry(
            id: currentId,
            title: currentTitle ?? '',
            content: contentBuffer.toString().trim(),
            metadata: entryMetadata[currentId],
            isPlainMarkdown: isPlainH1,
          ));
        } else if (hasPreamble && contentBuffer.toString().trim().isNotEmpty) {
          entries.add(_createEntry(
            id: 'preamble',
            title: '',
            content: contentBuffer.toString().trim(),
            metadata: null,
            isPlainMarkdown: true,
          ));
        }

        plainEntryCounter++;
        currentId = 'plain_$plainEntryCounter';
        currentTitle = trimmedLine.substring(2).trim();
        isPlainH1 = true;
        contentBuffer.clear();
      } else if (currentId != null) {
        contentBuffer.writeln(line);
      } else {
        contentBuffer.writeln(line);
        if (trimmedLine.isNotEmpty) {
          hasPreamble = true;
        }
      }
    }

    // Handle remaining content
    if (currentId == null && contentBuffer.toString().trim().isNotEmpty) {
      entries.add(_createEntry(
        id: 'preamble',
        title: '',
        content: contentBuffer.toString().trim(),
        metadata: null,
        isPlainMarkdown: true,
      ));
    }

    if (currentId != null) {
      entries.add(_createEntry(
        id: currentId,
        title: currentTitle ?? '',
        content: contentBuffer.toString().trim(),
        metadata: entryMetadata[currentId],
        isPlainMarkdown: isPlainH1,
      ));
    }

    return entries;
  }

  /// Create a JournalEntry from parsed data
  JournalEntry _createEntry({
    required String id,
    required String title,
    required String content,
    EntryMetadata? metadata,
    bool isPlainMarkdown = false,
  }) {
    // Strip trailing horizontal rules
    content = _stripTrailingHorizontalRule(content);

    final type = metadata?.type ?? JournalEntryType.text;

    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: type,
      createdAt: DateTime.now(),
      audioPath: metadata?.audioPath,
      imagePath: metadata?.imagePath,
      durationSeconds: metadata?.durationSeconds ?? 0,
      isPlainMarkdown: isPlainMarkdown,
    );
  }

  /// Strip trailing horizontal rules from content
  String _stripTrailingHorizontalRule(String content) {
    var trimmed = content.trim();
    while (trimmed.endsWith('---') || trimmed.endsWith('---\n')) {
      trimmed = trimmed.substring(0, trimmed.lastIndexOf('---')).trim();
    }
    return trimmed;
  }

  /// Serialize a JournalDay to markdown
  String _serializeJournal(JournalDay journal) {
    final buffer = StringBuffer();

    // Frontmatter
    buffer.writeln('---');
    buffer.writeln('date: ${journal.dateString}');

    if (journal.entryMetadata.isNotEmpty) {
      buffer.writeln('entries:');
      for (final entry in journal.entryMetadata.entries) {
        buffer.writeln('  ${entry.key}:');
        final yaml = entry.value.toYaml();
        for (final field in yaml.entries) {
          buffer.writeln('    ${field.key}: ${field.value}');
        }
      }
    }

    buffer.writeln('---');
    buffer.writeln();

    // Entries
    for (var i = 0; i < journal.entries.length; i++) {
      final entry = journal.entries[i];
      buffer.writeln(_serializeEntry(entry));

      if (i < journal.entries.length - 1) {
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  /// Serialize a single entry
  String _serializeEntry(JournalEntry entry) {
    final buffer = StringBuffer();

    if (entry.id == 'preamble') {
      if (entry.content.isNotEmpty) {
        buffer.write(entry.content);
      }
    } else if (entry.isPlainMarkdown) {
      buffer.writeln('# ${entry.title}');
      buffer.writeln();
      if (entry.content.isNotEmpty) {
        buffer.writeln(entry.content);
      }
    } else {
      buffer.writeln(ParaIdService.formatH1(entry.id, entry.title));
      buffer.writeln();
      if (entry.content.isNotEmpty) {
        buffer.writeln(entry.content);
      }
    }

    if (entry.id != 'preamble') {
      buffer.writeln();
      buffer.writeln('---');
    }

    return buffer.toString().trimRight();
  }

  /// Format date as YYYY-MM-DD
  static String _formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
