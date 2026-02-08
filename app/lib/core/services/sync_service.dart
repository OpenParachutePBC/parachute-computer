import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'file_system_service.dart';

/// Abstract interface for journal merge operations.
///
/// Consuming apps provide a concrete implementation (e.g., JournalMergeService)
/// to enable entry-level merge during sync conflicts.
abstract class JournalMerger {
  Future<JournalMergeResult> merge({
    required String localContent,
    required String serverContent,
    required DateTime date,
  });
}

/// Result of a journal merge operation
class JournalMergeResult {
  final String mergedContent;
  final bool hasConflicts;
  final List<String> conflictEntryIds;
  final int localOnlyCount;
  final int serverOnlyCount;

  JournalMergeResult({
    required this.mergedContent,
    this.hasConflicts = false,
    this.conflictEntryIds = const [],
    this.localOnlyCount = 0,
    this.serverOnlyCount = 0,
  });
}

/// File info from server manifest
class SyncFileInfo {
  final String path;
  final String hash;
  final int size;
  final double modified;

  SyncFileInfo({
    required this.path,
    required this.hash,
    required this.size,
    required this.modified,
  });

  factory SyncFileInfo.fromJson(Map<String, dynamic> json) {
    return SyncFileInfo(
      path: json['path'] as String,
      hash: json['hash'] as String,
      size: json['size'] as int,
      modified: (json['modified'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'hash': hash,
        'size': size,
        'modified': modified,
      };
}

/// Progress update during sync
class SyncProgress {
  final String phase; // 'scanning', 'pushing', 'pulling'
  final int current;
  final int total;
  final String? currentFile;

  SyncProgress({
    required this.phase,
    required this.current,
    required this.total,
    this.currentFile,
  });

  double get percentage => total > 0 ? current / total : 0;

  @override
  String toString() => '$phase: $current/$total${currentFile != null ? ' ($currentFile)' : ''}';
}

/// Callback for sync progress updates
typedef SyncProgressCallback = void Function(SyncProgress progress);

/// Result of a sync operation
class SyncResult {
  final bool success;
  final int pushed;
  final int pulled;
  final int deleted;
  final int merged;
  final List<String> errors;
  final List<String> conflicts;
  final Duration duration;

  SyncResult({
    required this.success,
    this.pushed = 0,
    this.pulled = 0,
    this.deleted = 0,
    this.merged = 0,
    this.errors = const [],
    this.conflicts = const [],
    this.duration = Duration.zero,
  });

  factory SyncResult.error(String message) {
    return SyncResult(
      success: false,
      errors: [message],
    );
  }

  @override
  String toString() {
    if (!success) {
      return 'SyncResult(failed: ${errors.join(", ")})';
    }
    final conflictStr = conflicts.isNotEmpty ? ', conflicts: ${conflicts.length}' : '';
    final mergedStr = merged > 0 ? ', merged: $merged' : '';
    return 'SyncResult(pushed: $pushed, pulled: $pulled, deleted: $deleted$mergedStr$conflictStr, duration: ${duration.inMilliseconds}ms)';
  }
}

/// Sync status for UI
enum SyncStatus {
  idle,
  syncing,
  success,
  error,
}

/// Service for syncing Daily files with the server.
///
/// Follows the same pattern as BaseServerService - singleton with
/// server URL from SharedPreferences.
///
/// Sync protocol:
/// 1. Get manifest from server (file paths + hashes)
/// 2. Compare with local files
/// 3. Push local changes (files that are newer locally)
/// 4. Pull remote changes (files that are newer on server)
/// 5. Handle deletes (files removed from either side)
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final FileSystemService _fileSystem = FileSystemService.daily();
  JournalMerger? _journalMerger;

  String? _serverUrl;
  String? _apiKey;
  bool _isInitialized = false;
  String? _deviceId;

  /// Key for storing device ID in SharedPreferences
  static const _deviceIdKey = 'sync_device_id';

  /// Threshold in seconds for detecting conflicts (close timestamps)
  static const _conflictThresholdSeconds = 60.0;

  /// Maximum versions to keep for each file
  static const _maxVersions = 3;

  /// Initialize the service with server URL
  Future<void> initialize({required String serverUrl, String? apiKey}) async {
    _serverUrl = serverUrl;
    _apiKey = apiKey;
    _isInitialized = true;
    _deviceId = await getDeviceId();
    debugPrint('[SyncService] Initialized with server: $serverUrl, deviceId: $_deviceId');
  }

  /// Set the journal merger (injected to avoid circular dependency)
  void setJournalMerger(JournalMerger merger) {
    _journalMerger = merger;
  }

  /// @deprecated Use setJournalMerger instead
  void setJournalMergeService(dynamic service) {
    if (service is JournalMerger) {
      _journalMerger = service;
    }
  }

  /// Check if service is ready
  bool get isReady => _isInitialized && _serverUrl != null;

  /// Get or generate a unique device ID (first 7 chars of SHA-256)
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);

    if (deviceId == null) {
      // Generate new device ID from device info
      final deviceInfo = DeviceInfoPlugin();
      String rawId;

      if (Platform.isAndroid) {
        final android = await deviceInfo.androidInfo;
        rawId = '${android.id}-${android.model}-${android.device}';
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        rawId = '${ios.identifierForVendor}-${ios.model}';
      } else if (Platform.isMacOS) {
        final macos = await deviceInfo.macOsInfo;
        rawId = '${macos.systemGUID}-${macos.model}';
      } else if (Platform.isLinux) {
        final linux = await deviceInfo.linuxInfo;
        rawId = '${linux.machineId}-${linux.name}';
      } else if (Platform.isWindows) {
        final windows = await deviceInfo.windowsInfo;
        rawId = '${windows.deviceId}-${windows.computerName}';
      } else {
        // Fallback: use timestamp + random
        rawId = '${DateTime.now().millisecondsSinceEpoch}-${DateTime.now().microsecond}';
      }

      // Hash and take first 7 characters
      final hash = sha256.convert(utf8.encode(rawId)).toString();
      deviceId = hash.substring(0, 7);

      await prefs.setString(_deviceIdKey, deviceId);
      debugPrint('[SyncService] Generated new device ID: $deviceId');
    }

    return deviceId;
  }

  /// Get HTTP headers including auth if configured
  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_apiKey';
    }
    return headers;
  }

  /// Compute SHA-256 hash of file content
  String _hashContent(String content) {
    return sha256.convert(utf8.encode(content)).toString();
  }

  /// Compute SHA-256 hash of file
  Future<String> _hashFile(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Binary file extensions to skip in text-only sync mode
  static const _binaryExtensions = {'.wav', '.mp3', '.m4a', '.ogg', '.opus', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf'};

  /// Check if a path is a journal file that supports entry-level merge
  bool _isJournalFile(String relativePath) {
    return relativePath.startsWith('journals/') && relativePath.endsWith('.md');
  }

  /// Parse date from journal file path (e.g., "journals/2025-01-16.md" -> DateTime)
  DateTime? _parseDateFromPath(String relativePath) {
    final filename = path.basenameWithoutExtension(relativePath);
    final parts = filename.split('-');
    if (parts.length != 3) return null;
    try {
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Save a version of a file before overwriting
  Future<void> _saveVersion(File file, String localRoot) async {
    if (!await file.exists()) return;

    final relativePath = path.relative(file.path, from: localRoot);
    final versionsDir = Directory('$localRoot/.versions/${path.dirname(relativePath)}');
    await versionsDir.create(recursive: true);

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final versionName = '${path.basename(file.path)}.$timestamp';

    await file.copy('${versionsDir.path}/$versionName');

    // Prune old versions
    await _pruneVersions(versionsDir, path.basename(file.path));

    debugPrint('[SyncService] Saved version: $relativePath');
  }

  /// Prune old versions, keeping only _maxVersions
  Future<void> _pruneVersions(Directory versionsDir, String basename) async {
    if (!await versionsDir.exists()) return;

    final versions = <File>[];
    await for (final entity in versionsDir.list()) {
      if (entity is File && path.basename(entity.path).startsWith(basename)) {
        versions.add(entity);
      }
    }

    if (versions.length <= _maxVersions) return;

    // Sort by timestamp in filename (older first)
    versions.sort((a, b) => a.path.compareTo(b.path));

    // Delete oldest versions
    for (var i = 0; i < versions.length - _maxVersions; i++) {
      await versions[i].delete();
      debugPrint('[SyncService] Pruned old version: ${versions[i].path}');
    }
  }

  /// Create a conflict file preserving the server version
  Future<void> _saveConflictFile(
    String localRoot,
    String relativePath,
    String serverContent,
  ) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
    final ext = path.extension(relativePath);
    final base = path.basenameWithoutExtension(relativePath);
    final dir = path.dirname(relativePath);

    final conflictName = '$base.sync-conflict-$timestamp-${_deviceId ?? 'unknown'}$ext';
    final conflictPath = '$localRoot/$dir/$conflictName';

    await File(conflictPath).parent.create(recursive: true);
    await File(conflictPath).writeAsString(serverContent);

    debugPrint('[SyncService] Created conflict file: $conflictName');
  }

  /// Create a tombstone file indicating a file was deleted
  Future<void> _createTombstone(String localRoot, String relativePath) async {
    final tombstonePath = '$localRoot/.tombstones/$relativePath.deleted';
    final tombstoneFile = File(tombstonePath);
    await tombstoneFile.parent.create(recursive: true);

    await tombstoneFile.writeAsString(json.encode({
      'deleted_at': DateTime.now().toIso8601String(),
      'device_id': _deviceId ?? 'unknown',
    }));

    debugPrint('[SyncService] Created tombstone: $relativePath');
  }

  /// Get list of tombstones (deleted files)
  Future<Map<String, Map<String, dynamic>>> _getTombstones(String localRoot) async {
    final tombstoneDir = Directory('$localRoot/.tombstones');
    final tombstones = <String, Map<String, dynamic>>{};

    if (!await tombstoneDir.exists()) return tombstones;

    await for (final entity in tombstoneDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.deleted')) continue;

      try {
        final content = await entity.readAsString();
        final data = json.decode(content) as Map<String, dynamic>;

        // Extract original path from tombstone path
        final relativeTombstonePath = path.relative(entity.path, from: '$localRoot/.tombstones');
        final originalPath = relativeTombstonePath.replaceAll('.deleted', '');

        tombstones[originalPath] = data;
      } catch (e) {
        debugPrint('[SyncService] Error reading tombstone ${entity.path}: $e');
      }
    }

    return tombstones;
  }

  /// Clean up old tombstones (older than 7 days)
  Future<void> _cleanOldTombstones(String localRoot) async {
    final tombstoneDir = Directory('$localRoot/.tombstones');
    if (!await tombstoneDir.exists()) return;

    final cutoff = DateTime.now().subtract(const Duration(days: 7));

    await for (final entity in tombstoneDir.list(recursive: true)) {
      if (entity is! File) continue;

      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
          debugPrint('[SyncService] Cleaned up old tombstone: ${entity.path}');
        }
      } catch (e) {
        // Ignore errors cleaning up tombstones
      }
    }
  }

  /// Delete a file and create a tombstone for sync
  Future<void> deleteFileWithTombstone(String relativePath) async {
    final localRoot = await _fileSystem.getRootPath();
    final file = File('$localRoot/$relativePath');

    // Save version before deleting
    if (await file.exists()) {
      await _saveVersion(file, localRoot);
      await file.delete();
    }

    // Create tombstone so deletion propagates to server
    await _createTombstone(localRoot, relativePath);
  }

  /// Fetch a single file's content from the server
  Future<String?> _fetchFileContent(String root, String relativePath) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/sync/pull'),
            headers: _headers,
            body: json.encode({
              'root': root,
              'paths': [relativePath],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      if (files.isEmpty) return null;

      final fileData = files.first as Map<String, dynamic>;
      final isBinary = fileData['is_binary'] as bool? ?? false;

      if (isBinary) return null; // Can't merge binary files

      return fileData['content'] as String;
    } catch (e) {
      debugPrint('[SyncService] Error fetching file content: $e');
      return null;
    }
  }

  /// Get local file info for a directory
  Future<Map<String, SyncFileInfo>> _getLocalManifest(
    String localRoot,
    String pattern, {
    bool includeBinary = false,
    bool quick = false,
  }) async {
    final manifest = <String, SyncFileInfo>{};
    final dir = Directory(localRoot);

    if (!await dir.exists()) {
      return manifest;
    }

    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;

      final relativePath = path.relative(entity.path, from: localRoot);
      final parts = relativePath.split('/');

      // Skip hidden files/dirs, EXCEPT .agents/ which we need to sync
      if (parts.any((part) => part.startsWith('.') && part != '.agents')) {
        continue;
      }
      if (parts.any((part) => part == '.versions' || part == '.tombstones')) {
        continue;
      }

      // Skip binary files unless includeBinary is true
      if (!includeBinary) {
        final ext = path.extension(relativePath).toLowerCase();
        if (_binaryExtensions.contains(ext)) {
          continue;
        }
      }

      // Match pattern
      if (pattern == '*.md' && !relativePath.endsWith('.md')) {
        continue;
      }
      if (pattern == '*' || relativePath.endsWith(pattern.replaceAll('*', ''))) {
        try {
          final stat = await entity.stat();
          final hash = quick
              ? (stat.modified.millisecondsSinceEpoch / 1000.0).toString()
              : await _hashFile(entity);

          manifest[relativePath] = SyncFileInfo(
            path: relativePath,
            hash: hash,
            size: stat.size,
            modified: stat.modified.millisecondsSinceEpoch / 1000.0,
          );
        } catch (e) {
          debugPrint('[SyncService] Error reading $relativePath: $e');
        }
      }
    }

    return manifest;
  }

  /// Get local file info for a specific date (date-scoped sync)
  Future<Map<String, SyncFileInfo>> _getLocalManifestForDate(
    String localRoot,
    String date, {
    bool includeBinary = false,
  }) async {
    final manifest = <String, SyncFileInfo>{};

    final filesToCheck = <String>[
      'journals/$date.md',
      'reflections/$date.md',
      'chat-log/$date.json',
      'chat-log/$date.md',
    ];

    for (final relativePath in filesToCheck) {
      final file = File('$localRoot/$relativePath');
      if (await file.exists()) {
        try {
          final stat = await file.stat();
          final hash = await _hashFile(file);

          manifest[relativePath] = SyncFileInfo(
            path: relativePath,
            hash: hash,
            size: stat.size,
            modified: stat.modified.millisecondsSinceEpoch / 1000.0,
          );
        } catch (e) {
          debugPrint('[SyncService] Error reading $relativePath: $e');
        }
      }
    }

    // Check new date-based assets folder
    final assetsDateDir = Directory('$localRoot/assets/$date');
    if (await assetsDateDir.exists()) {
      await for (final entity in assetsDateDir.list()) {
        if (entity is! File) continue;

        final relativePath = path.relative(entity.path, from: localRoot);
        final ext = path.extension(relativePath).toLowerCase();

        if (!includeBinary && _binaryExtensions.contains(ext)) {
          continue;
        }

        try {
          final stat = await entity.stat();
          final hash = await _hashFile(entity);

          manifest[relativePath] = SyncFileInfo(
            path: relativePath,
            hash: hash,
            size: stat.size,
            modified: stat.modified.millisecondsSinceEpoch / 1000.0,
          );
        } catch (e) {
          debugPrint('[SyncService] Error reading $relativePath: $e');
        }
      }
    }

    // Also check legacy month-based folder
    final month = date.substring(0, 7);
    final assetsMonthDir = Directory('$localRoot/assets/$month');
    if (await assetsMonthDir.exists()) {
      await for (final entity in assetsMonthDir.list()) {
        if (entity is! File) continue;

        final filename = path.basename(entity.path);
        if (!filename.startsWith(date)) continue;

        final relativePath = path.relative(entity.path, from: localRoot);
        final ext = path.extension(relativePath).toLowerCase();

        if (!includeBinary && _binaryExtensions.contains(ext)) {
          continue;
        }

        try {
          final stat = await entity.stat();
          final hash = await _hashFile(entity);

          manifest[relativePath] = SyncFileInfo(
            path: relativePath,
            hash: hash,
            size: stat.size,
            modified: stat.modified.millisecondsSinceEpoch / 1000.0,
          );
        } catch (e) {
          debugPrint('[SyncService] Error reading $relativePath: $e');
        }
      }
    }

    debugPrint('[SyncService] Local manifest for date $date: ${manifest.length} files');
    return manifest;
  }

  /// Get server manifest
  Future<Map<String, SyncFileInfo>?> getServerManifest(
    String root, {
    String pattern = '*.md',
    bool includeBinary = false,
    String? date,
    bool quick = false,
  }) async {
    if (!isReady) {
      debugPrint('[SyncService] Not initialized');
      return null;
    }

    try {
      final queryParams = {
        'root': root,
        'pattern': pattern,
        'include_binary': includeBinary.toString(),
        'quick': quick.toString(),
      };

      if (date != null) {
        queryParams['date'] = date;
      }

      final uri = Uri.parse('$_serverUrl/api/sync/manifest')
          .replace(queryParameters: queryParams);

      final response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[SyncService] Manifest error: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      final manifest = <String, SyncFileInfo>{};
      for (final file in files) {
        final info = SyncFileInfo.fromJson(file as Map<String, dynamic>);
        manifest[info.path] = info;
      }

      final scopeDesc = date != null ? 'date-scoped ($date)' : 'full';
      debugPrint('[SyncService] Server manifest ($scopeDesc): ${manifest.length} files');
      return manifest;
    } catch (e) {
      debugPrint('[SyncService] Error getting manifest: $e');
      return null;
    }
  }

  /// Get files changed on server since a timestamp
  Future<List<String>?> getServerChanges(
    String root, {
    required double sinceTimestamp,
    String pattern = '*.md',
    bool includeBinary = false,
  }) async {
    if (!isReady) return null;

    try {
      final uri = Uri.parse('$_serverUrl/api/sync/changes').replace(
        queryParameters: {
          'root': root,
          'since': sinceTimestamp.toString(),
          'pattern': pattern,
          'include_binary': includeBinary.toString(),
        },
      );

      final response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[SyncService] Changes error: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      final paths = files.map((f) => f['path'] as String).toList();
      debugPrint('[SyncService] Server changes since $sinceTimestamp: ${paths.length} files');
      return paths;
    } catch (e) {
      debugPrint('[SyncService] Error getting changes: $e');
      return null;
    }
  }

  /// Pull specific files from server and save locally
  Future<int> pullFiles(String root, List<String> relativePaths) async {
    if (!isReady || relativePaths.isEmpty) return 0;

    try {
      final localRoot = await _fileSystem.getRootPath();
      final pulled = await _pullFiles(root, localRoot, relativePaths);
      debugPrint('[SyncService] pullFiles(${relativePaths.length} files): pulled=$pulled');
      return pulled;
    } catch (e) {
      debugPrint('[SyncService] Error in pullFiles: $e');
      return 0;
    }
  }

  /// Push a single file to server
  Future<bool> pushFile(String root, String relativePath) async {
    if (!isReady) return false;

    try {
      final localRoot = await _fileSystem.getRootPath();
      final pushed = await _pushFiles(root, localRoot, [relativePath]);
      debugPrint('[SyncService] pushFile($relativePath): pushed=$pushed');
      return pushed > 0;
    } catch (e) {
      debugPrint('[SyncService] Error in pushFile: $e');
      return false;
    }
  }

  /// Push multiple specific files to server
  Future<int> pushFiles(String root, List<String> relativePaths) async {
    if (!isReady || relativePaths.isEmpty) return 0;

    try {
      final localRoot = await _fileSystem.getRootPath();
      final pushed = await _pushFiles(root, localRoot, relativePaths);
      debugPrint('[SyncService] pushFiles(${relativePaths.length} files): pushed=$pushed');
      return pushed;
    } catch (e) {
      debugPrint('[SyncService] Error in pushFiles: $e');
      return 0;
    }
  }

  /// Push files to server
  Future<int> _pushFiles(
    String root,
    String localRoot,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return 0;

    try {
      final files = <Map<String, dynamic>>[];

      for (final relativePath in paths) {
        final file = File('$localRoot/$relativePath');
        if (await file.exists()) {
          final ext = path.extension(relativePath).toLowerCase();
          final isBinary = _binaryExtensions.contains(ext);

          if (isBinary) {
            final bytes = await file.readAsBytes();
            files.add({
              'path': relativePath,
              'content': base64Encode(bytes),
              'is_binary': true,
            });
          } else {
            final content = await file.readAsString();
            files.add({
              'path': relativePath,
              'content': content,
              'is_binary': false,
            });
          }
        }
      }

      if (files.isEmpty) return 0;

      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/sync/push'),
            headers: _headers,
            body: json.encode({
              'root': root,
              'files': files,
            }),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        debugPrint('[SyncService] Push error: ${response.statusCode}');
        return 0;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['pushed'] as int? ?? 0;
    } catch (e) {
      debugPrint('[SyncService] Error pushing files: $e');
      return 0;
    }
  }

  /// Pull files from server
  Future<int> _pullFiles(
    String root,
    String localRoot,
    List<String> paths,
  ) async {
    if (paths.isEmpty) return 0;

    try {
      final response = await http
          .post(
            Uri.parse('$_serverUrl/api/sync/pull'),
            headers: _headers,
            body: json.encode({
              'root': root,
              'paths': paths,
            }),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode != 200) {
        debugPrint('[SyncService] Pull error: ${response.statusCode}');
        return 0;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      var pulled = 0;
      for (final fileData in files) {
        final filePath = fileData['path'] as String;
        final content = fileData['content'] as String;
        final isBinary = fileData['is_binary'] as bool? ?? false;

        final localFile = File('$localRoot/$filePath');

        if (await localFile.exists()) {
          await _saveVersion(localFile, localRoot);
        }

        await localFile.parent.create(recursive: true);

        if (isBinary) {
          await localFile.writeAsBytes(base64Decode(content));
        } else {
          await localFile.writeAsString(content);
        }
        pulled++;
      }

      return pulled;
    } catch (e) {
      debugPrint('[SyncService] Error pulling files: $e');
      return 0;
    }
  }

  /// Delete files on server
  Future<int> _deleteRemoteFiles(String root, List<String> paths) async {
    if (paths.isEmpty) return 0;

    try {
      final uri = Uri.parse('$_serverUrl/api/sync/files').replace(
        queryParameters: {
          'root': root,
          'paths': paths,
        },
      );

      final response = await http
          .delete(uri, headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[SyncService] Delete error: ${response.statusCode}');
        return 0;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['deleted'] as int? ?? 0;
    } catch (e) {
      debugPrint('[SyncService] Error deleting files: $e');
      return 0;
    }
  }

  /// Batch size for file operations
  static const int _textBatchSize = 50;
  static const int _binaryBatchSize = 5;

  /// Perform a full sync for a folder.
  Future<SyncResult> sync({
    String root = 'Daily',
    String pattern = '*',
    bool includeBinary = false,
    SyncProgressCallback? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    if (!isReady) {
      return SyncResult.error('Sync service not initialized');
    }

    try {
      final localRoot = await _fileSystem.getRootPath();
      debugPrint('[SyncService] Syncing $root: local=$localRoot, pattern=$pattern, includeBinary=$includeBinary');

      final serverManifest = await getServerManifest(root, pattern: pattern, includeBinary: includeBinary);
      if (serverManifest == null) {
        return SyncResult.error('Failed to get server manifest');
      }

      final localManifest = await _getLocalManifest(localRoot, pattern, includeBinary: includeBinary);
      debugPrint('[SyncService] Local: ${localManifest.length} files, Server: ${serverManifest.length} files');

      final toPush = <String>[];
      final toPull = <String>[];
      final toMerge = <String>[];
      final toDeleteRemote = <String>[];
      final conflicts = <String>[];

      for (final entry in localManifest.entries) {
        final localPath = entry.key;
        final localInfo = entry.value;
        final serverInfo = serverManifest[localPath];

        if (serverInfo == null) {
          toPush.add(localPath);
        } else if (localInfo.hash != serverInfo.hash) {
          final timeDiff = (localInfo.modified - serverInfo.modified).abs();

          if (timeDiff < _conflictThresholdSeconds) {
            toMerge.add(localPath);
          } else if (localInfo.modified > serverInfo.modified) {
            toPush.add(localPath);
          } else {
            toPull.add(localPath);
          }
        }
      }

      final tombstones = await _getTombstones(localRoot);
      for (final tombstonePath in tombstones.keys) {
        if (serverManifest.containsKey(tombstonePath)) {
          toDeleteRemote.add(tombstonePath);
          debugPrint('[SyncService] Tombstone -> delete remote: $tombstonePath');
        }
        final tombstoneFile = File('$localRoot/.tombstones/$tombstonePath.deleted');
        if (await tombstoneFile.exists()) {
          await tombstoneFile.delete();
        }
      }

      for (final serverPath in serverManifest.keys) {
        if (!localManifest.containsKey(serverPath) && !tombstones.containsKey(serverPath)) {
          toPull.add(serverPath);
        }
      }

      await _cleanOldTombstones(localRoot);

      debugPrint('[SyncService] To push: ${toPush.length}, To pull: ${toPull.length}, To merge: ${toMerge.length}, To delete remote: ${toDeleteRemote.length}');

      var merged = 0;
      for (final mergePath in toMerge) {
        onProgress?.call(SyncProgress(
          phase: 'merging',
          current: merged,
          total: toMerge.length,
          currentFile: mergePath,
        ));

        if (_isJournalFile(mergePath) && _journalMerger != null) {
          final date = _parseDateFromPath(mergePath);
          if (date != null) {
            try {
              final localContent = await File('$localRoot/$mergePath').readAsString();
              final serverContent = await _fetchFileContent(root, mergePath);

              if (serverContent != null) {
                final mergeResult = await _journalMerger!.merge(
                  localContent: localContent,
                  serverContent: serverContent,
                  date: date,
                );

                await _saveVersion(File('$localRoot/$mergePath'), localRoot);
                await File('$localRoot/$mergePath').writeAsString(mergeResult.mergedContent);
                toPush.add(mergePath);

                if (mergeResult.hasConflicts) {
                  for (final entryId in mergeResult.conflictEntryIds) {
                    debugPrint('[SyncService] Journal entry conflict: $mergePath entry=$entryId (local wins)');
                    conflicts.add('$mergePath#$entryId');
                  }
                }

                debugPrint('[SyncService] Merged journal: $mergePath (local=${mergeResult.localOnlyCount}, server=${mergeResult.serverOnlyCount}, conflicts=${mergeResult.conflictEntryIds.length})');
                merged++;
                continue;
              }
            } catch (e) {
              debugPrint('[SyncService] Journal merge failed for $mergePath: $e');
            }
          }
        }

        try {
          final serverContent = await _fetchFileContent(root, mergePath);
          if (serverContent != null) {
            await _saveConflictFile(localRoot, mergePath, serverContent);
            conflicts.add(mergePath);
          }
          toPush.add(mergePath);
        } catch (e) {
          debugPrint('[SyncService] Error handling conflict for $mergePath: $e');
        }
      }

      final textToPush = toPush.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPush = toPush.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final textToPull = toPull.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPull = toPull.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();

      final totalFiles = toPush.length + toPull.length;
      var processedFiles = 0;
      var pushed = 0;
      var pulled = 0;

      for (var i = 0; i < textToPush.length; i += _textBatchSize) {
        final batch = textToPush.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pushing', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < binaryToPush.length; i += _binaryBatchSize) {
        final batch = binaryToPush.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pushing', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < textToPull.length; i += _textBatchSize) {
        final batch = textToPull.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pulling', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pulled += await _pullFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < binaryToPull.length; i += _binaryBatchSize) {
        final batch = binaryToPull.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pulling', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pulled += await _pullFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      final deleted = await _deleteRemoteFiles(root, toDeleteRemote);

      stopwatch.stop();

      final result = SyncResult(
        success: true,
        pushed: pushed,
        pulled: pulled,
        deleted: deleted,
        merged: merged,
        conflicts: conflicts,
        duration: stopwatch.elapsed,
      );

      debugPrint('[SyncService] $result');
      return result;
    } catch (e) {
      stopwatch.stop();
      debugPrint('[SyncService] Sync error: $e');
      return SyncResult.error('Sync failed: $e');
    }
  }

  /// Quick check if server is reachable
  Future<bool> isServerReachable() async {
    if (!isReady) return false;

    try {
      final response = await http
          .get(Uri.parse('$_serverUrl/api/health'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Perform a date-scoped sync for a specific day.
  Future<SyncResult> syncDate({
    required String date,
    String root = 'Daily',
    bool includeBinary = false,
    SyncProgressCallback? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    if (!isReady) {
      return SyncResult.error('Sync service not initialized');
    }

    try {
      final localRoot = await _fileSystem.getRootPath();
      debugPrint('[SyncService] Date-scoped sync for $date: local=$localRoot, includeBinary=$includeBinary');

      final serverManifest = await getServerManifest(root, pattern: '*', includeBinary: includeBinary, date: date);
      if (serverManifest == null) {
        return SyncResult.error('Failed to get server manifest');
      }

      final localManifest = await _getLocalManifestForDate(localRoot, date, includeBinary: includeBinary);
      debugPrint('[SyncService] Date $date - Local: ${localManifest.length} files, Server: ${serverManifest.length} files');

      final toPush = <String>[];
      final toPull = <String>[];
      final toMerge = <String>[];
      final conflicts = <String>[];

      for (final entry in localManifest.entries) {
        final localPath = entry.key;
        final localInfo = entry.value;
        final serverInfo = serverManifest[localPath];

        if (serverInfo == null) {
          toPush.add(localPath);
        } else if (localInfo.hash != serverInfo.hash) {
          final timeDiff = (localInfo.modified - serverInfo.modified).abs();

          if (timeDiff < _conflictThresholdSeconds) {
            toMerge.add(localPath);
          } else if (localInfo.modified > serverInfo.modified) {
            toPush.add(localPath);
          } else {
            toPull.add(localPath);
          }
        }
      }

      for (final serverPath in serverManifest.keys) {
        if (!localManifest.containsKey(serverPath)) {
          toPull.add(serverPath);
        }
      }

      debugPrint('[SyncService] Date $date - To push: ${toPush.length}, To pull: ${toPull.length}, To merge: ${toMerge.length}');

      var merged = 0;
      for (final mergePath in toMerge) {
        onProgress?.call(SyncProgress(phase: 'merging', current: merged, total: toMerge.length, currentFile: mergePath));

        if (_isJournalFile(mergePath) && _journalMerger != null) {
          final fileDate = _parseDateFromPath(mergePath);
          if (fileDate != null) {
            try {
              final localContent = await File('$localRoot/$mergePath').readAsString();
              final serverContent = await _fetchFileContent(root, mergePath);

              if (serverContent != null) {
                final mergeResult = await _journalMerger!.merge(
                  localContent: localContent,
                  serverContent: serverContent,
                  date: fileDate,
                );

                await _saveVersion(File('$localRoot/$mergePath'), localRoot);
                await File('$localRoot/$mergePath').writeAsString(mergeResult.mergedContent);
                toPush.add(mergePath);

                if (mergeResult.hasConflicts) {
                  for (final entryId in mergeResult.conflictEntryIds) {
                    conflicts.add('$mergePath#$entryId');
                  }
                }

                merged++;
                continue;
              }
            } catch (e) {
              debugPrint('[SyncService] Journal merge failed for $mergePath: $e');
            }
          }
        }

        try {
          final serverContent = await _fetchFileContent(root, mergePath);
          if (serverContent != null) {
            await _saveConflictFile(localRoot, mergePath, serverContent);
            conflicts.add(mergePath);
          }
          toPush.add(mergePath);
        } catch (e) {
          debugPrint('[SyncService] Error handling conflict for $mergePath: $e');
        }
      }

      final textToPush = toPush.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPush = toPush.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final textToPull = toPull.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPull = toPull.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();

      final totalFiles = toPush.length + toPull.length;
      var processedFiles = 0;
      var pushed = 0;
      var pulled = 0;

      for (var i = 0; i < textToPush.length; i += _textBatchSize) {
        final batch = textToPush.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pushing', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < binaryToPush.length; i += _binaryBatchSize) {
        final batch = binaryToPush.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pushing', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < textToPull.length; i += _textBatchSize) {
        final batch = textToPull.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pulling', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pulled += await _pullFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      for (var i = 0; i < binaryToPull.length; i += _binaryBatchSize) {
        final batch = binaryToPull.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(phase: 'pulling', current: processedFiles, total: totalFiles, currentFile: batch.isNotEmpty ? batch.first : null));
        pulled += await _pullFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      stopwatch.stop();

      final result = SyncResult(
        success: true,
        pushed: pushed,
        pulled: pulled,
        deleted: 0,
        merged: merged,
        conflicts: conflicts,
        duration: stopwatch.elapsed,
      );

      debugPrint('[SyncService] Date-scoped sync complete: $result');
      return result;
    } catch (e) {
      stopwatch.stop();
      debugPrint('[SyncService] Date-scoped sync error: $e');
      return SyncResult.error('Date-scoped sync failed: $e');
    }
  }
}
