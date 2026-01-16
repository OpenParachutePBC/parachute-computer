import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'file_system_service.dart';

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
  final List<String> errors;
  final Duration duration;

  SyncResult({
    required this.success,
    this.pushed = 0,
    this.pulled = 0,
    this.deleted = 0,
    this.errors = const [],
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
    return 'SyncResult(pushed: $pushed, pulled: $pulled, deleted: $deleted, duration: ${duration.inMilliseconds}ms)';
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

  String? _serverUrl;
  String? _apiKey;
  bool _isInitialized = false;

  /// Initialize the service with server URL
  Future<void> initialize({required String serverUrl, String? apiKey}) async {
    _serverUrl = serverUrl;
    _apiKey = apiKey;
    _isInitialized = true;
    debugPrint('[SyncService] Initialized with server: $serverUrl');
  }

  /// Check if service is ready
  bool get isReady => _isInitialized && _serverUrl != null;

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
  static const _binaryExtensions = {'.wav', '.mp3', '.m4a', '.ogg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf'};

  /// Get local file info for a directory
  Future<Map<String, SyncFileInfo>> _getLocalManifest(
    String localRoot,
    String pattern, {
    bool includeBinary = false,
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

      // Skip binary files unless includeBinary is true
      if (!includeBinary) {
        final ext = path.extension(relativePath).toLowerCase();
        if (_binaryExtensions.contains(ext)) {
          continue;
        }
      }

      // Match pattern (simple glob: *.md matches all .md files)
      if (pattern == '*.md' && !relativePath.endsWith('.md')) {
        continue;
      }
      if (pattern == '*' || relativePath.endsWith(pattern.replaceAll('*', ''))) {
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

    return manifest;
  }

  /// Get server manifest for a sync root
  Future<Map<String, SyncFileInfo>?> getServerManifest(
    String root, {
    String pattern = '*.md',
    bool includeBinary = false,
  }) async {
    if (!isReady) {
      debugPrint('[SyncService] Not initialized');
      return null;
    }

    try {
      final uri = Uri.parse('$_serverUrl/api/sync/manifest')
          .replace(queryParameters: {
            'root': root,
            'pattern': pattern,
            'include_binary': includeBinary.toString(),
          });

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

      debugPrint('[SyncService] Server manifest: ${manifest.length} files');
      return manifest;
    } catch (e) {
      debugPrint('[SyncService] Error getting manifest: $e');
      return null;
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
            // Read as bytes and base64 encode
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
          .timeout(const Duration(seconds: 120)); // Longer timeout for binary files

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
          .timeout(const Duration(seconds: 120)); // Longer timeout for binary files

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
        await localFile.parent.create(recursive: true);

        if (isBinary) {
          // Decode base64 and write as bytes
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

  /// Batch size for file operations (smaller for binary to avoid timeouts)
  static const int _textBatchSize = 50;
  static const int _binaryBatchSize = 5;

  /// Perform a full sync for a folder.
  ///
  /// [root] - The sync root on the server (e.g., "Daily")
  /// [pattern] - Glob pattern for files to sync (e.g., "*.md" or "*" for all)
  /// [includeBinary] - Whether to include binary files (audio, images)
  /// [onProgress] - Callback for progress updates
  ///
  /// For your local setup, use pattern "*" to sync everything.
  /// For the $1 tier, we'll use "*.md" to only sync markdown.
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
      // Get local Daily folder path
      final localRoot = await _fileSystem.getRootPath();
      debugPrint('[SyncService] Syncing $root: local=$localRoot, pattern=$pattern, includeBinary=$includeBinary');

      // Get manifests
      final serverManifest = await getServerManifest(root, pattern: pattern, includeBinary: includeBinary);
      if (serverManifest == null) {
        return SyncResult.error('Failed to get server manifest');
      }

      final localManifest = await _getLocalManifest(localRoot, pattern, includeBinary: includeBinary);
      debugPrint('[SyncService] Local: ${localManifest.length} files, Server: ${serverManifest.length} files');

      // Determine what needs to sync
      final toPush = <String>[]; // Local files to push to server
      final toPull = <String>[]; // Server files to pull locally
      final toDeleteRemote = <String>[]; // Files to delete on server

      // Check all local files
      for (final entry in localManifest.entries) {
        final localPath = entry.key;
        final localInfo = entry.value;
        final serverInfo = serverManifest[localPath];

        if (serverInfo == null) {
          // File exists locally but not on server - push it
          toPush.add(localPath);
        } else if (localInfo.hash != serverInfo.hash) {
          // File exists both places but differs - use timestamp to decide
          if (localInfo.modified > serverInfo.modified) {
            toPush.add(localPath);
          } else {
            toPull.add(localPath);
          }
        }
        // If hashes match, file is in sync
      }

      // Check for server-only files (pull them)
      for (final serverPath in serverManifest.keys) {
        if (!localManifest.containsKey(serverPath)) {
          toPull.add(serverPath);
        }
      }

      debugPrint('[SyncService] To push: ${toPush.length}, To pull: ${toPull.length}');

      // Separate text and binary files for batching
      final textToPush = toPush.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPush = toPush.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final textToPull = toPull.where((p) => !_binaryExtensions.contains(path.extension(p).toLowerCase())).toList();
      final binaryToPull = toPull.where((p) => _binaryExtensions.contains(path.extension(p).toLowerCase())).toList();

      final totalFiles = toPush.length + toPull.length;
      var processedFiles = 0;
      var pushed = 0;
      var pulled = 0;

      // Push text files in batches
      for (var i = 0; i < textToPush.length; i += _textBatchSize) {
        final batch = textToPush.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(
          phase: 'pushing',
          current: processedFiles,
          total: totalFiles,
          currentFile: batch.isNotEmpty ? batch.first : null,
        ));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      // Push binary files in smaller batches
      for (var i = 0; i < binaryToPush.length; i += _binaryBatchSize) {
        final batch = binaryToPush.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(
          phase: 'pushing',
          current: processedFiles,
          total: totalFiles,
          currentFile: batch.isNotEmpty ? batch.first : null,
        ));
        pushed += await _pushFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      // Pull text files in batches
      for (var i = 0; i < textToPull.length; i += _textBatchSize) {
        final batch = textToPull.skip(i).take(_textBatchSize).toList();
        onProgress?.call(SyncProgress(
          phase: 'pulling',
          current: processedFiles,
          total: totalFiles,
          currentFile: batch.isNotEmpty ? batch.first : null,
        ));
        pulled += await _pullFiles(root, localRoot, batch);
        processedFiles += batch.length;
      }

      // Pull binary files in smaller batches
      for (var i = 0; i < binaryToPull.length; i += _binaryBatchSize) {
        final batch = binaryToPull.skip(i).take(_binaryBatchSize).toList();
        onProgress?.call(SyncProgress(
          phase: 'pulling',
          current: processedFiles,
          total: totalFiles,
          currentFile: batch.isNotEmpty ? batch.first : null,
        ));
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
}
