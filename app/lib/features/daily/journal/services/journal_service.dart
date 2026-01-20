import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import '../models/entry_metadata.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import 'para_id_service.dart';

/// Callback type for journal data changes
typedef JournalChangeCallback = void Function();

/// Service for reading and writing journal files.
///
/// Handles parsing markdown files with YAML frontmatter and H1-delimited
/// entries in the format: `# para:abc123 Title here`
///
/// Uses FileSystemService for all file operations.
class JournalService {
  final String _vaultPath;
  final String _journalFolderName;
  final ParaIdService _paraIdService;
  final FileSystemService _fileSystemService;
  final _log = logger.createLogger('JournalService');

  /// Optional callback triggered when journal data changes (add/update/delete)
  JournalChangeCallback? onDataChanged;

  JournalService._({
    required String vaultPath,
    required String journalFolderName,
    required ParaIdService paraIdService,
    required FileSystemService fileSystemService,
    this.onDataChanged,
  })  : _vaultPath = vaultPath,
        _journalFolderName = journalFolderName,
        _paraIdService = paraIdService,
        _fileSystemService = fileSystemService;

  /// Factory constructor that uses FileSystemService for configuration
  static Future<JournalService> create({
    required FileSystemService fileSystemService,
    required ParaIdService paraIdService,
  }) async {
    final vaultPath = await fileSystemService.getRootPath();
    final journalFolderName = fileSystemService.getJournalFolderName();
    return JournalService._(
      vaultPath: vaultPath,
      journalFolderName: journalFolderName,
      paraIdService: paraIdService,
      fileSystemService: fileSystemService,
    );
  }

  /// Path to journals directory
  /// If folder name is empty, returns the vault root path
  String get journalsPath {
    if (_journalFolderName.isEmpty) {
      return _vaultPath;
    }
    return '$_vaultPath/$_journalFolderName';
  }

  /// Ensure journals directory exists
  Future<void> ensureDirectoryExists() async {
    final created = await _fileSystemService.ensureDirectoryExists(journalsPath);
    if (created) {
      _log.info('Ensured journals directory exists');
    }
  }

  /// Get the file path for a specific date
  String getFilePath(DateTime date) {
    final dateStr = _formatDate(date);
    return '$journalsPath/$dateStr.md';
  }

  /// Load a journal day from disk
  ///
  /// Returns an empty journal if the file doesn't exist.
  Future<JournalDay> loadDay(DateTime date) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      _log.debug('Journal file not found, returning empty', data: {'date': _formatDate(normalizedDate)});
      return _createEmptyJournal(normalizedDate);
    }

    try {
      final content = await _fileSystemService.readFileAsString(filePath);
      if (content == null) {
        _log.warn('Could not read journal file', data: {'date': _formatDate(normalizedDate)});
        return _createEmptyJournal(normalizedDate);
      }

      final journal = _parseJournalFile(content, normalizedDate);

      // Register any para IDs we found
      for (final entry in journal.entries) {
        await _paraIdService.register(entry.id);
      }

      return journal;
    } catch (e, st) {
      _log.error('Failed to load journal', error: e, stackTrace: st, data: {'date': _formatDate(normalizedDate)});
      rethrow;
    }
  }

  /// Load today's journal
  Future<JournalDay> loadToday() => loadDay(DateTime.now());

  /// Save a journal day to disk
  Future<void> saveDay(JournalDay journal) async {
    await ensureDirectoryExists();

    final filePath = '$_vaultPath/${journal.filePath}';
    final content = _serializeJournal(journal);

    try {
      final success = await _fileSystemService.writeFileAsString(filePath, content);
      if (!success) {
        throw Exception('Failed to write journal file');
      }
    } catch (e, st) {
      _log.error('Failed to save journal', error: e, stackTrace: st, data: {'date': journal.dateString});
      rethrow;
    }
  }

  /// Add a new entry to a journal day (uses surgical file append)
  ///
  /// Appends the entry to the file without rewriting existing content.
  /// This preserves any external edits to the file.
  Future<({JournalEntry entry, JournalDay journal})> addEntry({
    required DateTime date,
    required String title,
    required String content,
    JournalEntryType type = JournalEntryType.text,
    String? audioPath,
    String? linkedFilePath,
    String? imagePath,
    int? durationSeconds,
    bool isPendingTranscription = false,
    bool? linedBackground,
  }) async {
    // Use surgical append - preserves external edits
    final entry = await appendEntryToFile(
      date: date,
      title: title,
      content: content,
      type: type,
      audioPath: audioPath,
      linkedFilePath: linkedFilePath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      isPendingTranscription: isPendingTranscription,
      linedBackground: linedBackground,
    );

    // Reload the journal to get updated state
    final journal = await loadDay(date);

    // Notify listeners of data change
    onDataChanged?.call();

    return (entry: entry, journal: journal);
  }

  /// Add a text entry to today's journal
  /// Returns both the entry and updated journal for optimistic UI updates.
  Future<({JournalEntry entry, JournalDay journal})> addTextEntry({
    required String content,
    String? title,
  }) async {
    final now = DateTime.now();
    final defaultTitle = _formatTime(now);

    return addEntry(
      date: now,
      title: title ?? defaultTitle,
      content: content,
      type: JournalEntryType.text,
    );
  }

  /// Add a voice entry to today's journal
  ///
  /// Copies the audio file to the journal assets folder and stores the relative path.
  /// Returns both the entry and updated journal for optimistic UI updates.
  Future<({JournalEntry entry, JournalDay journal})> addVoiceEntry({
    required String transcript,
    required String audioPath,
    required int durationSeconds,
    String? title,
  }) async {
    final now = DateTime.now();
    final defaultTitle = _formatTime(now);

    // Get path in unified assets folder (assets/YYYY-MM/)
    // Preserve the original file extension (wav, opus, etc.)
    final sourceExtension = audioPath.split('.').last.toLowerCase();
    final extension = ['wav', 'opus', 'mp3', 'ogg', 'm4a'].contains(sourceExtension)
        ? sourceExtension
        : 'wav';
    final destPath = await _fileSystemService.getNewAssetPath(now, 'audio', extension);
    final audioFilename = destPath.split('/').last;
    final relativePath = _fileSystemService.getAssetRelativePath(now, audioFilename);

    // Copy the audio file
    final sourceFile = File(audioPath);
    if (await sourceFile.exists()) {
      try {
        await sourceFile.copy(destPath);
      } catch (e) {
        _log.warn('Could not copy audio file', data: {'error': e.toString()});
      }

      // Only delete temp file if we have a transcript (non-streaming mode)
      // In streaming mode (empty transcript), we need the temp file for transcription
      if (transcript.isNotEmpty) {
        try {
          await sourceFile.delete();
        } catch (e) {
          _log.warn('Could not delete temp audio file', data: {'error': e.toString()});
        }
      }
    } else {
      _log.warn('Audio file not found', data: {'path': audioPath});
    }

    // Determine if transcription is pending (empty transcript means waiting for transcription)
    final isPending = transcript.isEmpty;

    return addEntry(
      date: now,
      title: title ?? defaultTitle,
      content: isPending ? '*(Transcribing...)*' : transcript,
      type: JournalEntryType.voice,
      audioPath: relativePath,
      durationSeconds: durationSeconds,
      isPendingTranscription: isPending,
    );
  }

  /// Add a linked entry (for long recordings moved to separate files)
  /// Returns both the entry and updated journal for optimistic UI updates.
  Future<({JournalEntry entry, JournalDay journal})> addLinkedEntry({
    required String linkedFilePath,
    String? audioPath,
    int? durationSeconds,
    String? title,
  }) async {
    final now = DateTime.now();
    final defaultTitle = _formatTime(now);

    return addEntry(
      date: now,
      title: title ?? defaultTitle,
      content: '',
      type: JournalEntryType.linked,
      linkedFilePath: linkedFilePath,
      audioPath: audioPath,
      durationSeconds: durationSeconds,
    );
  }

  /// Add a photo entry to today's journal
  ///
  /// The image should already be saved to the assets folder.
  /// Pass the relative path (e.g., "assets/2025-12/...").
  /// Returns both the entry and updated journal for optimistic UI updates.
  Future<({JournalEntry entry, JournalDay journal})> addPhotoEntry({
    required String imagePath,
    String? extractedText,
    String? title,
  }) async {
    final now = DateTime.now();
    final defaultTitle = _formatTime(now);

    return addEntry(
      date: now,
      title: title ?? defaultTitle,
      content: extractedText ?? '',
      type: JournalEntryType.photo,
      imagePath: imagePath,
    );
  }

  /// Add a handwriting entry to today's journal
  ///
  /// The canvas image should already be saved to the assets folder.
  /// Pass the relative path (e.g., "assets/2025-12/...").
  /// Returns both the entry and updated journal for optimistic UI updates.
  Future<({JournalEntry entry, JournalDay journal})> addHandwritingEntry({
    required String imagePath,
    String? extractedText,
    String? title,
    bool linedBackground = false,
  }) async {
    final now = DateTime.now();
    final defaultTitle = _formatTime(now);

    return addEntry(
      date: now,
      title: title ?? defaultTitle,
      content: extractedText ?? '',
      type: JournalEntryType.handwriting,
      imagePath: imagePath,
      linedBackground: linedBackground,
    );
  }

  /// Update an existing entry (uses surgical file edit)
  Future<void> updateEntry(DateTime date, JournalEntry entry) async {
    await updateEntryInFile(date, entry);
    onDataChanged?.call();
  }

  /// Update transcription status for an entry
  Future<void> updateTranscriptionStatus(
    DateTime date,
    String entryId,
    TranscriptionStatus status,
  ) async {
    await _updateMetadataStatus(date, entryId, status);
    _log.info('Updated transcription status', data: {
      'date': _formatDate(date),
      'id': entryId,
      'status': status.name,
    });
  }

  /// Delete an entry (uses surgical file edit)
  Future<void> deleteEntry(DateTime date, String entryId) async {
    await deleteEntryFromFile(date, entryId);

    _log.info('Deleted journal entry', data: {
      'date': _formatDate(date),
      'id': entryId,
    });
    onDataChanged?.call();
  }

  // ============================================================
  // Surgical File Operations
  // ============================================================
  // These methods modify specific parts of the file without rewriting
  // everything, which is safer when files may be edited externally.

  /// Append an entry to the end of a journal file
  ///
  /// This is the safest operation - it only appends, never overwrites.
  /// External changes to the file are preserved.
  Future<JournalEntry> appendEntryToFile({
    required DateTime date,
    required String title,
    required String content,
    JournalEntryType type = JournalEntryType.text,
    String? audioPath,
    String? linkedFilePath,
    String? imagePath,
    int? durationSeconds,
    bool isPendingTranscription = false,
    bool? linedBackground,
  }) async {
    await ensureDirectoryExists();

    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);
    final id = await _paraIdService.generate();
    final now = DateTime.now();

    final entry = JournalEntry(
      id: id,
      title: title,
      content: content,
      type: type,
      createdAt: now,
      audioPath: audioPath,
      linkedFilePath: linkedFilePath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      isPendingTranscription: isPendingTranscription,
    );

    // Create metadata for frontmatter
    EntryMetadata? metadata;
    if (type == JournalEntryType.voice && audioPath != null) {
      metadata = EntryMetadata.voice(
        audioPath: audioPath,
        durationSeconds: durationSeconds ?? 0,
        createdTime: _formatTime(now),
        hasPendingTranscription: isPendingTranscription,
      );
    } else if (type == JournalEntryType.text) {
      metadata = EntryMetadata.text(createdTime: _formatTime(now));
    } else if (type == JournalEntryType.photo && imagePath != null) {
      metadata = EntryMetadata.photo(
        imagePath: imagePath,
        createdTime: _formatTime(now),
      );
    } else if (type == JournalEntryType.handwriting && imagePath != null) {
      metadata = EntryMetadata.handwriting(
        imagePath: imagePath,
        createdTime: _formatTime(now),
        linedBackground: linedBackground ?? false,
      );
    }

    // Read existing file content (or create new)
    String existingContent = '';
    bool fileExists = await _fileSystemService.fileExists(filePath);
    if (fileExists) {
      existingContent = await _fileSystemService.readFileAsString(filePath) ?? '';
    }

    String newContent;
    if (existingContent.isEmpty) {
      // New file - create with frontmatter
      newContent = _createNewFileWithEntry(normalizedDate, entry, metadata);
    } else {
      // Existing file - append entry and update frontmatter if needed
      newContent = _appendEntryToContent(existingContent, entry, metadata);
    }

    final success = await _fileSystemService.writeFileAsString(filePath, newContent);
    if (!success) {
      throw Exception('Failed to append entry to journal file');
    }

    _log.info('Appended entry to journal', data: {
      'date': _formatDate(normalizedDate),
      'id': id,
      'type': type.name,
    });

    return entry;
  }

  /// Update a specific entry block in the file
  ///
  /// Finds the block by its para:ID and replaces only that section.
  /// Everything else in the file is preserved byte-for-byte.
  Future<void> updateEntryInFile(DateTime date, JournalEntry entry) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      throw Exception('Journal file not found');
    }

    final content = await _fileSystemService.readFileAsString(filePath);
    if (content == null) {
      throw Exception('Could not read journal file');
    }

    final newContent = _replaceEntryBlock(content, entry);

    final success = await _fileSystemService.writeFileAsString(filePath, newContent);
    if (!success) {
      throw Exception('Failed to update entry in journal file');
    }

    _log.info('Updated entry in journal (surgical)', data: {
      'date': _formatDate(normalizedDate),
      'id': entry.id,
    });
  }

  /// Delete a specific entry block from the file
  ///
  /// Finds the block by its para:ID and removes only that section.
  /// Everything else in the file is preserved.
  Future<void> deleteEntryFromFile(DateTime date, String entryId) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      _log.warn('Journal file not found for delete', data: {'date': _formatDate(normalizedDate)});
      return;
    }

    final content = await _fileSystemService.readFileAsString(filePath);
    if (content == null) {
      throw Exception('Could not read journal file');
    }

    final newContent = _removeEntryBlock(content, entryId);

    final success = await _fileSystemService.writeFileAsString(filePath, newContent);
    if (!success) {
      throw Exception('Failed to delete entry from journal file');
    }

    _log.info('Deleted entry from journal (surgical)', data: {
      'date': _formatDate(normalizedDate),
      'id': entryId,
    });
  }

  /// Create a new file with frontmatter and one entry
  String _createNewFileWithEntry(DateTime date, JournalEntry entry, EntryMetadata? metadata) {
    final buffer = StringBuffer();

    // Frontmatter
    buffer.writeln('---');
    buffer.writeln('date: ${_formatDate(date)}');
    if (metadata != null) {
      buffer.writeln('entries:');
      buffer.writeln('  ${entry.id}:');
      final yaml = metadata.toYaml();
      for (final field in yaml.entries) {
        buffer.writeln('    ${field.key}: ${field.value}');
      }
    }
    buffer.writeln('---');
    buffer.writeln();

    // Entry
    buffer.writeln(_serializeEntry(entry));

    return buffer.toString();
  }

  /// Append an entry to existing file content
  String _appendEntryToContent(String content, JournalEntry entry, EntryMetadata? metadata) {
    // If we have metadata, we need to update the frontmatter
    if (metadata != null) {
      content = _addMetadataToFrontmatter(content, entry.id, metadata);
    }

    // Ensure there's a newline at the end before appending
    if (!content.endsWith('\n')) {
      content += '\n';
    }
    if (!content.endsWith('\n\n')) {
      content += '\n';
    }

    // Append the new entry
    content += _serializeEntry(entry);
    content += '\n';

    return content;
  }

  /// Add entry metadata to the frontmatter
  String _addMetadataToFrontmatter(String content, String id, EntryMetadata metadata) {
    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    final yaml = metadata.toYaml();
    final metadataLines = StringBuffer();
    metadataLines.writeln('  $id:');
    for (final field in yaml.entries) {
      metadataLines.writeln('    ${field.key}: ${field.value}');
    }

    if (frontmatter.isEmpty) {
      // No frontmatter - create one
      final buffer = StringBuffer();
      buffer.writeln('---');
      buffer.writeln('entries:');
      buffer.write(metadataLines);
      buffer.writeln('---');
      buffer.writeln();
      buffer.write(body);
      return buffer.toString();
    }

    // Has frontmatter - check if entries section exists
    final lines = frontmatter.split('\n');
    final buffer = StringBuffer();
    buffer.writeln('---');

    bool hasEntries = lines.any((l) => l.trim().startsWith('entries:'));
    bool addedEntry = false;

    for (final line in lines) {
      buffer.writeln(line);

      // Add new entry right after "entries:" line
      if (line.trim() == 'entries:' && !addedEntry) {
        buffer.write(metadataLines);
        addedEntry = true;
      }
    }

    // If no entries section existed, add it
    if (!hasEntries) {
      buffer.writeln('entries:');
      buffer.write(metadataLines);
    }

    buffer.writeln('---');
    buffer.writeln();
    buffer.write(body);

    return buffer.toString();
  }

  /// Find and replace a specific entry block in the content
  String _replaceEntryBlock(String content, JournalEntry entry) {
    final blockRange = _findEntryBlockRange(content, entry.id);
    if (blockRange == null) {
      _log.warn('Entry block not found for replacement', data: {'id': entry.id});
      // Fall back to appending - create metadata if we have audio
      EntryMetadata? metadata;
      if (entry.audioPath != null) {
        metadata = EntryMetadata.voice(
          audioPath: entry.audioPath!,
          durationSeconds: entry.durationSeconds ?? 0,
          createdTime: _formatTime(entry.createdAt),
          hasPendingTranscription: entry.isPendingTranscription,
        );
      }
      return _appendEntryToContent(content, entry, metadata);
    }

    final before = content.substring(0, blockRange.$1);
    final after = content.substring(blockRange.$2);

    // Build new block
    final newBlock = '${_serializeEntry(entry)}\n';

    var result = '$before$newBlock$after';

    // Update frontmatter metadata transcription status if entry is a voice entry
    // If entry has content, it's been transcribed - update status to complete
    if (entry.type == JournalEntryType.voice && entry.content.isNotEmpty) {
      result = _updateMetadataStatusInContent(result, entry.id, TranscriptionStatus.complete);
    }

    return result;
  }

  /// Update transcription status in the frontmatter metadata (in-memory string operation)
  String _updateMetadataStatusInContent(String content, String entryId, TranscriptionStatus status) {
    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    if (frontmatter.isEmpty) return content;

    final lines = frontmatter.split('\n');
    final buffer = StringBuffer();

    bool inTargetEntry = false;
    int entryIndent = 0;
    bool statusUpdated = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final indent = line.length - trimmed.length;

      // Check if this line starts the target entry
      if (trimmed.startsWith('$entryId:')) {
        inTargetEntry = true;
        entryIndent = indent;
        buffer.writeln(line);
        continue;
      }

      // Check if we've exited the target entry (same or less indent, non-empty)
      if (inTargetEntry && trimmed.isNotEmpty && indent <= entryIndent) {
        inTargetEntry = false;
      }

      // Update status line if in target entry
      if (inTargetEntry && trimmed.startsWith('status:')) {
        buffer.writeln('${' ' * (entryIndent + 2)}status: ${status.name}');
        statusUpdated = true;
        continue;
      }

      buffer.writeln(line);
    }

    // If status wasn't found/updated, the metadata might be in old format - that's OK
    if (!statusUpdated) {
      _log.debug('No status field found to update', data: {'entryId': entryId});
    }

    return '---\n${buffer.toString().trim()}\n---\n$body';
  }

  /// Find and remove a specific entry block from the content
  String _removeEntryBlock(String content, String entryId) {
    final blockRange = _findEntryBlockRange(content, entryId);
    if (blockRange == null) {
      _log.warn('Entry block not found for deletion', data: {'id': entryId});
      return content;
    }

    final before = content.substring(0, blockRange.$1);
    final after = content.substring(blockRange.$2);

    // Also remove the metadata from frontmatter
    var result = before + after;
    result = _removeMetadataFromFrontmatter(result, entryId);

    // Clean up excessive newlines
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return result;
  }

  /// Find the start and end position of an entry block by its ID
  /// Returns (startIndex, endIndex) or null if not found
  (int, int)? _findEntryBlockRange(String content, String entryId) {
    // Look for "# para:ID" pattern
    final headerPattern = RegExp(r'^# para:' + RegExp.escape(entryId) + r'[ \t]', multiLine: true);
    final match = headerPattern.firstMatch(content);

    if (match == null) {
      return null;
    }

    final startIndex = match.start;

    // Find the end - next H1 or end of file
    // Look for any line starting with "# " after this block
    final afterStart = content.substring(match.end);
    final nextH1 = RegExp(r'^# ', multiLine: true).firstMatch(afterStart);

    int endIndex;
    if (nextH1 != null) {
      endIndex = match.end + nextH1.start;
    } else {
      endIndex = content.length;
    }

    return (startIndex, endIndex);
  }

  /// Remove metadata for an entry from the frontmatter
  /// Handles both old `assets:` and new `entries:` format
  String _removeMetadataFromFrontmatter(String content, String id) {
    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    if (frontmatter.isEmpty) return content;

    final lines = frontmatter.split('\n');
    final buffer = StringBuffer();
    buffer.writeln('---');

    bool skipUntilNextEntry = false;
    int entryIndent = 0;

    for (final line in lines) {
      // Check if this line starts an entry for the ID we want to remove
      final trimmed = line.trimLeft();
      final indent = line.length - trimmed.length;

      // New format: entries section with nested properties
      if (trimmed.startsWith('$id:')) {
        // Skip this entry and all its nested properties
        skipUntilNextEntry = true;
        entryIndent = indent;
        continue;
      }

      // If we're skipping and hit a line with same or less indent, stop skipping
      if (skipUntilNextEntry) {
        if (trimmed.isNotEmpty && indent <= entryIndent) {
          skipUntilNextEntry = false;
        } else {
          continue;
        }
      }

      buffer.writeln(line);
    }

    buffer.writeln('---');
    buffer.writeln();
    buffer.write(body);

    return buffer.toString();
  }

  /// Update the status field in metadata for an entry
  Future<void> _updateMetadataStatus(
    DateTime date,
    String entryId,
    TranscriptionStatus status,
  ) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      _log.warn('Journal file not found for status update', data: {'date': _formatDate(normalizedDate)});
      return;
    }

    final content = await _fileSystemService.readFileAsString(filePath);
    if (content == null) {
      throw Exception('Could not read journal file');
    }

    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    if (frontmatter.isEmpty) return;

    final lines = frontmatter.split('\n');
    final buffer = StringBuffer();
    buffer.writeln('---');

    bool inTargetEntry = false;
    int entryIndent = 0;
    bool statusUpdated = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      final indent = line.length - trimmed.length;

      // Check if this line starts the target entry
      if (trimmed.startsWith('$entryId:')) {
        inTargetEntry = true;
        entryIndent = indent;
        buffer.writeln(line);
        continue;
      }

      // If we're in the target entry
      if (inTargetEntry) {
        // Check if we've left the entry (same or less indent)
        if (trimmed.isNotEmpty && indent <= entryIndent) {
          inTargetEntry = false;
        } else if (trimmed.startsWith('status:')) {
          // Update the status line
          buffer.writeln('${' ' * (entryIndent + 4)}status: ${status.name}');
          statusUpdated = true;
          continue;
        }
      }

      buffer.writeln(line);
    }

    buffer.writeln('---');
    buffer.writeln();
    buffer.write(body);

    if (statusUpdated) {
      final success = await _fileSystemService.writeFileAsString(filePath, buffer.toString());
      if (!success) {
        throw Exception('Failed to update metadata status');
      }
    }
  }

  /// List all available journal dates (most recent first)
  Future<List<DateTime>> listJournalDates() async {
    await ensureDirectoryExists();

    final files = await _fileSystemService.listDirectory(journalsPath);
    final dates = <DateTime>[];

    for (final filePath in files) {
      if (filePath.endsWith('.md')) {
        final filename = filePath.split('/').last;
        final dateStr = filename.replaceAll('.md', '');
        final date = _parseDate(dateStr);
        if (date != null) {
          dates.add(date);
        }
      }
    }

    dates.sort((a, b) => b.compareTo(a)); // Most recent first
    return dates;
  }

  // ============================================================
  // Helpers
  // ============================================================

  /// Create an empty JournalDay with the correct file path
  JournalDay _createEmptyJournal(DateTime date) {
    return JournalDay(
      date: DateTime(date.year, date.month, date.day),
      entries: const [],
      entryMetadata: const {},
      filePath: _getRelativeFilePath(date),
    );
  }

  /// Get the relative file path for a date (relative to vault root)
  /// Handles empty folder name case (journals stored in root)
  String _getRelativeFilePath(DateTime date) {
    final dateStr = _formatDate(date);
    if (_journalFolderName.isEmpty) {
      return '$dateStr.md';
    }
    return '$_journalFolderName/$dateStr.md';
  }

  // ============================================================
  // Parsing
  // ============================================================

  JournalDay _parseJournalFile(String content, DateTime date) {
    final parts = _splitFrontmatter(content);
    final frontmatter = parts.$1;
    final body = parts.$2;

    // Parse frontmatter - supports both old `assets:` and new `entries:` format
    Map<String, EntryMetadata> entryMetadata = {};
    if (frontmatter.isNotEmpty) {
      try {
        final yaml = loadYaml(frontmatter);
        if (yaml is Map) {
          // New format: entries with rich metadata
          if (yaml['entries'] is Map) {
            final entriesYaml = yaml['entries'] as Map;
            for (final entry in entriesYaml.entries) {
              final id = entry.key.toString();
              final value = entry.value;
              if (value is Map) {
                entryMetadata[id] = EntryMetadata.fromYaml(value);
              }
            }
          }
          // Old format: simple assets mapping (para ID -> audio path)
          else if (yaml['assets'] is Map) {
            final assets = yaml['assets'] as Map;
            for (final entry in assets.entries) {
              final id = entry.key.toString();
              final audioPath = entry.value.toString();
              entryMetadata[id] = EntryMetadata.fromAudioPath(audioPath);
            }
          }
        }
      } catch (e) {
        _log.warn('Failed to parse frontmatter', data: {'error': e.toString()});
      }
    }

    // Parse entries
    final entries = _parseEntries(body, entryMetadata);

    return JournalDay(
      date: date,
      entries: entries,
      entryMetadata: entryMetadata,
      filePath: _getRelativeFilePath(date),
    );
  }

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

  List<JournalEntry> _parseEntries(String body, Map<String, EntryMetadata> entryMetadata) {
    if (body.isEmpty) return [];

    final entries = <JournalEntry>[];
    final lines = body.split('\n');

    String? currentId;
    String? currentTitle;
    bool isPlainH1 = false;
    final contentBuffer = StringBuffer();
    int plainEntryCounter = 0;
    bool hasPreamble = false; // Track if we have preamble content before first H1

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
          // Save preamble content before this para: H1
          final preambleContent = contentBuffer.toString().trim();
          entries.add(_createEntry(
            id: 'preamble',
            title: '',
            content: preambleContent,
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
          // Save preamble content before this plain H1
          final preambleContent = contentBuffer.toString().trim();
          entries.add(_createEntry(
            id: 'preamble',
            title: '',
            content: preambleContent,
            metadata: null,
            isPlainMarkdown: true,
          ));
        }

        // Start new plain entry with generated ID
        plainEntryCounter++;
        currentId = 'plain_$plainEntryCounter';
        currentTitle = trimmedLine.substring(2).trim(); // Remove "# "
        isPlainH1 = true;
        contentBuffer.clear();
      } else if (currentId != null) {
        // Add to current entry's content
        contentBuffer.writeln(line);
      } else {
        // Content before any H1 - accumulate as preamble
        // Preserve all lines (including blank) for preamble formatting
        contentBuffer.writeln(line);
        if (trimmedLine.isNotEmpty) {
          hasPreamble = true;
        }
      }
    }

    // Handle content before any H1 (preamble) - only if no H1 was ever found
    if (currentId == null && contentBuffer.toString().trim().isNotEmpty) {
      entries.add(_createEntry(
        id: 'preamble',
        title: '',
        content: contentBuffer.toString().trim(),
        metadata: null,
        isPlainMarkdown: true,
      ));
    }

    // Don't forget the last entry
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

  JournalEntry _createEntry({
    required String id,
    required String title,
    required String content,
    EntryMetadata? metadata,
    bool isPlainMarkdown = false,
  }) {
    // Strip trailing horizontal rules (---) which are used for visual separation in the file
    content = _stripTrailingHorizontalRule(content);

    // Detect entry type from content or metadata
    final linkedFile = _extractWikilink(content);

    // Use metadata type if available, otherwise detect from content
    final type = metadata?.type ??
        (linkedFile != null
            ? JournalEntryType.linked
            : metadata?.audioPath != null
                ? JournalEntryType.voice
                : metadata?.imagePath != null
                    ? JournalEntryType.photo
                    : JournalEntryType.text);

    // Check if this is a pending transcription
    final isPending = metadata?.transcriptionStatus == TranscriptionStatus.pending ||
        metadata?.transcriptionStatus == TranscriptionStatus.transcribing;

    return JournalEntry(
      id: id,
      title: title,
      content: content,
      type: type,
      createdAt: DateTime.now(),
      linkedFilePath: linkedFile,
      audioPath: metadata?.audioPath,
      imagePath: metadata?.imagePath,
      durationSeconds: metadata?.durationSeconds ?? 0,
      isPlainMarkdown: isPlainMarkdown,
      isPendingTranscription: isPending,
    );
  }

  String? _extractWikilink(String content) {
    // Match [[path]] or [[path|display]]
    final regex = RegExp(r'\[\[([^\]|]+)(?:\|[^\]]+)?\]\]');
    final match = regex.firstMatch(content);
    return match?.group(1);
  }

  // ============================================================
  // Serialization
  // ============================================================

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

      // Add blank line between entries (but not after last)
      if (i < journal.entries.length - 1) {
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  String _serializeEntry(JournalEntry entry) {
    final buffer = StringBuffer();

    // Handle different entry types:
    // 1. Preamble - no H1, just content
    // 2. Plain H1s - preserve without para: prefix
    // 3. Para entries - use para:ID format
    if (entry.id == 'preamble') {
      // Preamble: just content, no header
      if (entry.content.isNotEmpty) {
        buffer.write(entry.content);
      }
    } else if (entry.isPlainMarkdown) {
      // Plain H1: preserve original format without para:
      buffer.writeln('# ${entry.title}');
      buffer.writeln();
      if (entry.content.isNotEmpty) {
        buffer.writeln(entry.content);
      }
    } else {
      // Para entry: use para:ID format
      buffer.writeln(ParaIdService.formatH1(entry.id, entry.title));
      buffer.writeln();

      // Content
      if (entry.isLinked && entry.linkedFilePath != null) {
        buffer.writeln('See [[${entry.linkedFilePath}]]');
      } else if (entry.content.isNotEmpty) {
        buffer.writeln(entry.content);
      }
    }

    // Add horizontal rule after entry (except preamble)
    if (entry.id != 'preamble') {
      buffer.writeln();
      buffer.writeln('---');
    }

    return buffer.toString().trimRight();
  }

  // ============================================================
  // Utilities
  // ============================================================

  static String _formatDate(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  static String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static DateTime? _parseDate(String dateStr) {
    try {
      final parts = dateStr.split('-');
      if (parts.length != 3) return null;
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Strip trailing horizontal rules (---) from content
  ///
  /// These are added for visual separation in the markdown file
  /// but shouldn't be displayed in the UI.
  static String _stripTrailingHorizontalRule(String content) {
    var trimmed = content.trim();
    // Remove trailing --- (with optional whitespace)
    while (trimmed.endsWith('---') || trimmed.endsWith('---\n')) {
      trimmed = trimmed.substring(0, trimmed.lastIndexOf('---')).trim();
    }
    return trimmed;
  }
}
