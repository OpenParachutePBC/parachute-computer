import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import '../models/reflection.dart';

/// Service for reading daily reflections.
///
/// Reflections are AI-generated summaries stored in {journalPath}/reflections/{date}.md
/// They are created by daily agents running on the Parachute Computer server.
class ReflectionService {
  final String _journalPath;
  final FileSystemService _fileSystemService;
  final _log = logger.createLogger('ReflectionService');

  ReflectionService._({
    required String journalPath,
    required FileSystemService fileSystemService,
  })  : _journalPath = journalPath,
        _fileSystemService = fileSystemService;

  /// Factory constructor
  static Future<ReflectionService> create({
    required FileSystemService fileSystemService,
  }) async {
    // Use the configured reflections path from FileSystemService
    final reflectionsPath = await fileSystemService.getReflectionsPath();
    return ReflectionService._(
      journalPath: reflectionsPath,
      fileSystemService: fileSystemService,
    );
  }

  /// Path to reflections directory (configured via settings)
  String get reflectionsPath => _journalPath;

  /// Get the file path for a reflection on a specific date
  String getFilePath(DateTime date) {
    final dateStr = _formatDate(date);
    return '$reflectionsPath/$dateStr.md';
  }

  /// Check if a reflection exists for a given date
  Future<bool> hasReflection(DateTime date) async {
    final filePath = getFilePath(date);
    return await _fileSystemService.fileExists(filePath);
  }

  /// Load a reflection for a specific date
  ///
  /// Returns null if no reflection exists for that date.
  Future<Reflection?> loadReflection(DateTime date) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      _log.debug('No reflection found', data: {'date': _formatDate(normalizedDate)});
      return null;
    }

    try {
      final content = await _fileSystemService.readFileAsString(filePath);
      if (content == null) {
        _log.debug('Reflection file empty', data: {'date': _formatDate(normalizedDate)});
        return null;
      }
      return _parseReflection(content, normalizedDate);
    } catch (e) {
      _log.error('Failed to load reflection', error: e, data: {'date': _formatDate(normalizedDate)});
      return null;
    }
  }

  /// Parse a reflection from markdown with YAML frontmatter
  Reflection _parseReflection(String content, DateTime date) {
    String body = content;
    DateTime? generatedAt;

    // Try to parse YAML frontmatter
    if (content.startsWith('---')) {
      final endIndex = content.indexOf('---', 3);
      if (endIndex != -1) {
        final frontmatter = content.substring(3, endIndex).trim();
        body = content.substring(endIndex + 3).trim();

        try {
          final yaml = loadYaml(frontmatter);
          if (yaml is YamlMap) {
            final generatedAtStr = yaml['generated_at'];
            if (generatedAtStr != null) {
              generatedAt = DateTime.tryParse(generatedAtStr.toString());
            }
          }
        } catch (e) {
          _log.warn('Failed to parse reflection frontmatter', error: e);
        }
      }
    }

    // Remove the "## Reflection - {date}" header if present
    // to get cleaner content for display
    final headerPattern = RegExp(r'^##\s*Reflection\s*-?\s*\d{4}-\d{2}-\d{2}\s*\n+', multiLine: true);
    body = body.replaceFirst(headerPattern, '');

    return Reflection(
      date: date,
      content: body.trim(),
      generatedAt: generatedAt,
    );
  }

  /// List all dates that have reflections
  Future<List<DateTime>> listReflectionDates() async {
    final dates = <DateTime>[];

    final dir = Directory(reflectionsPath);
    if (!await dir.exists()) {
      return dates;
    }

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.md')) {
        final filename = entity.uri.pathSegments.last;
        final dateStr = filename.replaceAll('.md', '');
        final date = DateTime.tryParse(dateStr);
        if (date != null) {
          dates.add(date);
        }
      }
    }

    dates.sort((a, b) => b.compareTo(a)); // Most recent first
    return dates;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
