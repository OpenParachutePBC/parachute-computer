import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';

/// Module type for the file system service
enum ModuleType {
  /// Daily module - ~/Parachute/Daily (offline-capable, synced)
  daily,

  /// Chat module - ~/Parachute/Chat (server-managed)
  chat,
}

/// Unified file system service for Parachute
///
/// Manages modular vault structures:
/// - ~/Parachute/Daily/ - Daily journals, assets, reflections (local, synced)
/// - ~/Parachute/Chat/ - Chat sessions, contexts, artifacts (server-managed)
///
/// Each module has its own instance with separate paths and preferences.
///
/// Philosophy: Files are the source of truth, databases are indexes.
class FileSystemService {
  // ============================================================
  // Instance Management - One instance per module
  // ============================================================

  static final Map<ModuleType, FileSystemService> _instances = {};

  /// Get or create service instance for a module
  factory FileSystemService.forModule(ModuleType moduleType) {
    return _instances.putIfAbsent(moduleType, () {
      return FileSystemService._internal(moduleType);
    });
  }

  /// Convenience factory for Daily module
  factory FileSystemService.daily() => FileSystemService.forModule(ModuleType.daily);

  /// Convenience factory for Chat module
  factory FileSystemService.chat() => FileSystemService.forModule(ModuleType.chat);

  final ModuleType _moduleType;
  FileSystemService._internal(this._moduleType);

  // ============================================================
  // Constants
  // ============================================================

  // SharedPreferences key prefix
  String get _keyPrefix => 'parachute_${_moduleType.name}_';

  String get _rootPathKey => '${_keyPrefix}root_path';
  String get _secureBookmarkKey => '${_keyPrefix}secure_bookmark';
  String get _userConfiguredKey => '${_keyPrefix}user_configured';

  // Temp audio folder (shared across modules)
  static const String _tempAudioFolderName = 'parachute_audio_temp';
  static const String _tempRecordingsSubfolder = 'recordings';
  static const String _tempPlaybackSubfolder = 'playback';
  static const String _tempSegmentsSubfolder = 'segments';

  // Retention policies
  static const Duration _recordingsTempMaxAge = Duration(days: 7);
  static const Duration _playbackTempMaxAge = Duration(hours: 24);
  static const Duration _segmentsTempMaxAge = Duration(hours: 1);

  // ============================================================
  // Private State
  // ============================================================

  String? _rootFolderPath;
  String? _tempAudioPath;
  final Map<String, String> _folderNames = {};
  bool _isInitialized = false;
  Future<void>? _initializationFuture;

  final SecureBookmarks? _secureBookmarks =
      Platform.isMacOS ? SecureBookmarks() : null;
  bool _isAccessingSecurityScopedResource = false;

  // ============================================================
  // Folder Configuration by Module
  // ============================================================

  /// Get default folder configuration for this module
  Map<String, _FolderConfig> get _folderConfigs {
    switch (_moduleType) {
      case ModuleType.daily:
        return {
          'journals': _FolderConfig(
            prefKey: '${_keyPrefix}journals_folder',
            defaultName: 'journals',
            required: false, // Can store in root
          ),
          'assets': _FolderConfig(
            prefKey: '${_keyPrefix}assets_folder',
            defaultName: 'assets',
            required: true,
          ),
          'reflections': _FolderConfig(
            prefKey: '${_keyPrefix}reflections_folder',
            defaultName: 'reflections',
            required: false,
          ),
          'chat-log': _FolderConfig(
            prefKey: '${_keyPrefix}chatlog_folder',
            defaultName: 'chat-log',
            required: false,
          ),
        };

      case ModuleType.chat:
        return {
          'sessions': _FolderConfig(
            prefKey: '${_keyPrefix}sessions_folder',
            defaultName: 'sessions',
            required: false,
          ),
          'assets': _FolderConfig(
            prefKey: '${_keyPrefix}assets_folder',
            defaultName: 'assets',
            required: true,
          ),
          'artifacts': _FolderConfig(
            prefKey: '${_keyPrefix}artifacts_folder',
            defaultName: 'artifacts',
            required: true,
          ),
          'contexts': _FolderConfig(
            prefKey: '${_keyPrefix}contexts_folder',
            defaultName: 'contexts',
            required: false,
          ),
          'imports': _FolderConfig(
            prefKey: '${_keyPrefix}imports_folder',
            defaultName: 'imports',
            required: false,
          ),
        };
    }
  }

  // ============================================================
  // Public API - Initialization
  // ============================================================

  /// Initialize the file system service
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initializationFuture != null) {
      return _initializationFuture;
    }

    _initializationFuture = _doInitialize();
    await _initializationFuture;
  }

  Future<void> _doInitialize() async {
    try {
      debugPrint('[FileSystemService:${_moduleType.name}] Starting initialization...');
      final prefs = await SharedPreferences.getInstance();

      _rootFolderPath = prefs.getString(_rootPathKey);

      if (_rootFolderPath == null) {
        _rootFolderPath = await _getDefaultRootPath();
        debugPrint('[FileSystemService:${_moduleType.name}] Set default root: $_rootFolderPath');
        await prefs.setString(_rootPathKey, _rootFolderPath!);
      } else {
        debugPrint('[FileSystemService:${_moduleType.name}] Loaded saved root: $_rootFolderPath');

        // macOS: restore security-scoped bookmark
        if (Platform.isMacOS && _secureBookmarks != null) {
          final bookmarkData = prefs.getString(_secureBookmarkKey);
          if (bookmarkData != null) {
            try {
              final resolvedEntity =
                  await _secureBookmarks.resolveBookmark(bookmarkData);
              await _secureBookmarks
                  .startAccessingSecurityScopedResource(resolvedEntity);
              _isAccessingSecurityScopedResource = true;

              final resolvedPath = resolvedEntity.path;
              if (resolvedPath != _rootFolderPath) {
                _rootFolderPath = resolvedPath;
                await prefs.setString(_rootPathKey, _rootFolderPath!);
              }
            } catch (e) {
              debugPrint(
                  '[FileSystemService:${_moduleType.name}] Failed to restore secure bookmark: $e');
            }
          }
        }

        // Verify access
        if (!_isAccessingSecurityScopedResource) {
          final savedDir = Directory(_rootFolderPath!);
          bool hasAccess = false;

          try {
            if (await savedDir.exists()) {
              hasAccess = true;
            } else {
              await savedDir.create(recursive: true);
              hasAccess = true;
            }
          } catch (e) {
            debugPrint(
                '[FileSystemService:${_moduleType.name}] Lost access to saved path: $e');
          }

          if (!hasAccess && (Platform.isMacOS || Platform.isIOS)) {
            _rootFolderPath = await _getDefaultRootPath();
            await prefs.setString(_rootPathKey, _rootFolderPath!);
          }
        }
      }

      // Load folder names from preferences
      for (final entry in _folderConfigs.entries) {
        final name = prefs.getString(entry.value.prefKey) ?? entry.value.defaultName;
        _folderNames[entry.key] = name;
        debugPrint(
            '[FileSystemService:${_moduleType.name}] ${entry.key} folder: ${name.isEmpty ? "(root)" : name}');
      }

      await _ensureFolderStructure();
      await cleanupTempAudioFiles();

      _isInitialized = true;
      _initializationFuture = null;
      debugPrint('[FileSystemService:${_moduleType.name}] Initialization complete');
    } catch (e, stackTrace) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error during initialization: $e');
      debugPrint('[FileSystemService:${_moduleType.name}] Stack trace: $stackTrace');
      _initializationFuture = null;
      rethrow;
    }
  }

  // ============================================================
  // Public API - Root Path
  // ============================================================

  /// Get the root folder path
  Future<String> getRootPath() async {
    await initialize();
    return _rootFolderPath!;
  }

  /// Get user-friendly root path display (with ~ for home)
  Future<String> getRootPathDisplay() async {
    final path = await getRootPath();

    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && path.startsWith(home)) {
        return path.replaceFirst(home, '~');
      }
    }

    return path;
  }

  /// Check if user has configured a custom path
  Future<bool> isUserConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_userConfiguredKey) ?? false;
  }

  /// Mark path as user-configured
  Future<void> markAsConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_userConfiguredKey, true);
  }

  /// Set custom root path with optional file migration
  Future<bool> setRootPath(String path, {bool migrateFiles = true}) async {
    try {
      final oldRootPath = _rootFolderPath;

      final newDir = Directory(path);
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
      }

      // Migrate files if requested
      if (migrateFiles && oldRootPath != null && oldRootPath != path) {
        final oldDir = Directory(oldRootPath);
        if (await oldDir.exists()) {
          debugPrint(
              '[FileSystemService:${_moduleType.name}] Migrating files from $oldRootPath to $path');
          await _copyDirectory(oldDir, Directory(path));
        }
      }

      // macOS: create security-scoped bookmark
      if (Platform.isMacOS && _secureBookmarks != null) {
        try {
          if (_isAccessingSecurityScopedResource && _rootFolderPath != null) {
            try {
              final oldDir = Directory(_rootFolderPath!);
              await _secureBookmarks.stopAccessingSecurityScopedResource(oldDir);
            } catch (e) {
              debugPrint(
                  '[FileSystemService:${_moduleType.name}] Error stopping old resource access: $e');
            }
            _isAccessingSecurityScopedResource = false;
          }

          final bookmarkData = await _secureBookmarks.bookmark(newDir);

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_secureBookmarkKey, bookmarkData);

          await _secureBookmarks.startAccessingSecurityScopedResource(newDir);
          _isAccessingSecurityScopedResource = true;
        } catch (e) {
          debugPrint(
              '[FileSystemService:${_moduleType.name}] Failed to create secure bookmark: $e');
        }
      }

      _rootFolderPath = path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rootPathKey, path);
      await prefs.setBool(_userConfiguredKey, true);

      await _ensureFolderStructure();

      return true;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error setting root path: $e');
      return false;
    }
  }

  /// Reset to default path
  Future<bool> resetToDefaultPath() async {
    final defaultPath = await _getDefaultRootPath();
    return setRootPath(defaultPath, migrateFiles: false);
  }

  // ============================================================
  // Public API - Folder Access
  // ============================================================

  /// Get folder name for a folder type
  String getFolderName(String folderType) {
    return _folderNames[folderType] ?? '';
  }

  /// Get folder path for a folder type
  Future<String> getFolderPath(String folderType) async {
    final root = await getRootPath();
    final name = _folderNames[folderType] ?? '';
    if (name.isEmpty) return root;
    return '$root/$name';
  }

  /// Check if folder exists
  Future<bool> hasFolderPath(String folderType) async {
    final path = await getFolderPath(folderType);
    return Directory(path).exists();
  }

  /// Ensure folder exists
  Future<String> ensureFolderExists(String folderType) async {
    final path = await getFolderPath(folderType);
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      debugPrint('[FileSystemService:${_moduleType.name}] Created $folderType folder: $path');
    }
    return path;
  }

  /// Set custom folder names
  Future<bool> setFolderNames(Map<String, String> folderNames) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      for (final entry in folderNames.entries) {
        final folderType = entry.key;
        final newName = entry.value;
        final config = _folderConfigs[folderType];

        if (config != null && newName.isNotEmpty) {
          _folderNames[folderType] = newName;
          await prefs.setString(config.prefKey, newName);
        }
      }

      await _ensureFolderStructure();
      return true;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error setting folder names: $e');
      return false;
    }
  }

  // ============================================================
  // Public API - Assets (Month-based organization)
  // ============================================================

  // ============================================================
  // Legacy Compatibility Methods (Daily module)
  // ============================================================

  /// Get journals folder name (legacy)
  String getJournalFolderName() => getFolderName('journals');

  /// Get journal path (legacy)
  Future<String> getJournalPath() => getFolderPath('journals');

  /// Get assets folder name (legacy)
  String getAssetsFolderName() => getFolderName('assets');

  /// Get assets path (legacy)
  Future<String> getAssetsPath() => getFolderPath('assets');

  /// Get reflections folder name (legacy)
  String getReflectionsFolderName() => getFolderName('reflections');

  /// Get reflections path (legacy)
  Future<String> getReflectionsPath() => getFolderPath('reflections');

  /// Get chat log folder name (legacy)
  String getChatLogFolderName() => getFolderName('chat-log');

  /// Get chat log path (legacy)
  Future<String> getChatLogPath() => getFolderPath('chat-log');

  /// Get new image path (legacy)
  Future<String> getNewImagePath(DateTime timestamp, String type) async {
    return getNewAssetPath(timestamp, type, 'png');
  }

  // ============================================================
  // Legacy Compatibility Methods (Chat module)
  // ============================================================

  /// Get sessions folder name (legacy)
  String getSessionsFolderName() => getFolderName('sessions');

  /// Get sessions path (legacy)
  Future<String> getSessionsPath() => getFolderPath('sessions');

  /// Get contexts folder name (legacy)
  String getContextsFolderName() => getFolderName('contexts');

  /// Get contexts path (legacy)
  Future<String> getContextsPath() => getFolderPath('contexts');

  /// Get imports folder name (legacy)
  String getImportsFolderName() => getFolderName('imports');

  /// Get imports path (legacy)
  Future<String> getImportsPath() => getFolderPath('imports');

  // ============================================================
  // Public API - Assets (Month-based organization)
  // ============================================================

  /// Get month folder path for assets (YYYY-MM)
  Future<String> getAssetsMonthPath(DateTime timestamp) async {
    final assetsPath = await getFolderPath('assets');
    final month =
        '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}';
    return '$assetsPath/$month';
  }

  /// Ensure month folder exists
  Future<String> ensureAssetsMonthFolderExists(DateTime timestamp) async {
    final monthPath = await getAssetsMonthPath(timestamp);
    final monthDir = Directory(monthPath);
    if (!await monthDir.exists()) {
      await monthDir.create(recursive: true);
      debugPrint('[FileSystemService:${_moduleType.name}] Created assets folder: $monthPath');
    }
    return monthPath;
  }

  /// Generate unique asset filename
  String generateAssetFilename(
      DateTime timestamp, String type, String extension) {
    final date =
        '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}';
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}';
    return '${date}_${time}_$type.$extension';
  }

  /// Get full path for new asset
  Future<String> getNewAssetPath(
      DateTime timestamp, String type, String extension) async {
    final monthPath = await ensureAssetsMonthFolderExists(timestamp);
    final filename = generateAssetFilename(timestamp, type, extension);
    return '$monthPath/$filename';
  }

  /// Get relative path from root to asset
  String getAssetRelativePath(DateTime timestamp, String filename) {
    final month =
        '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}';
    final assetsName = _folderNames['assets'] ?? 'assets';
    return '$assetsName/$month/$filename';
  }

  /// Resolve relative asset path to absolute
  Future<String> resolveAssetPath(String relativePath) async {
    final root = await getRootPath();
    return '$root/$relativePath';
  }

  // ============================================================
  // Public API - Temp Audio Files
  // ============================================================

  /// Get temp audio folder path
  Future<String> getTempAudioPath() async {
    if (_tempAudioPath != null) {
      return _tempAudioPath!;
    }

    final tempDir = await getTemporaryDirectory();
    _tempAudioPath = '${tempDir.path}/$_tempAudioFolderName';

    await _ensureTempFolderStructure();

    return _tempAudioPath!;
  }

  /// Get recording temp path
  Future<String> getRecordingTempPath() async {
    final tempPath = await getTempAudioPath();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '$tempPath/$_tempRecordingsSubfolder/recording_$timestamp.wav';
  }

  /// Get playback temp path
  Future<String> getPlaybackTempPath(String sourceOpusPath) async {
    final tempPath = await getTempAudioPath();
    final sourceFileName =
        sourceOpusPath.split('/').last.replaceAll('.opus', '');
    return '$tempPath/$_tempPlaybackSubfolder/playback_$sourceFileName.wav';
  }

  /// Get transcription segment temp path
  Future<String> getTranscriptionSegmentPath(int segmentIndex) async {
    final tempPath = await getTempAudioPath();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '$tempPath/$_tempSegmentsSubfolder/segment_${timestamp}_$segmentIndex.wav';
  }

  /// Get generic temp WAV path
  Future<String> getTempWavPath({String prefix = 'temp'}) async {
    final tempPath = await getTempAudioPath();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '$tempPath/$_tempSegmentsSubfolder/${prefix}_$timestamp.wav';
  }

  /// Cleanup old temp files
  Future<int> cleanupTempAudioFiles() async {
    var totalDeleted = 0;

    try {
      final tempPath = await getTempAudioPath();

      totalDeleted += await _cleanupTempSubfolder(
        '$tempPath/$_tempRecordingsSubfolder',
        _recordingsTempMaxAge,
      );
      totalDeleted += await _cleanupTempSubfolder(
        '$tempPath/$_tempPlaybackSubfolder',
        _playbackTempMaxAge,
      );
      totalDeleted += await _cleanupTempSubfolder(
        '$tempPath/$_tempSegmentsSubfolder',
        _segmentsTempMaxAge,
      );

      if (totalDeleted > 0) {
        debugPrint(
            '[FileSystemService:${_moduleType.name}] Cleaned up $totalDeleted temp files');
      }
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error cleaning temp files: $e');
    }

    return totalDeleted;
  }

  /// Clear all temp audio files
  Future<int> clearAllTempAudioFiles() async {
    try {
      final tempPath = await getTempAudioPath();
      final tempDir = Directory(tempPath);

      if (!await tempDir.exists()) return 0;

      var deletedCount = 0;
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is File) {
          try {
            await entity.delete();
            deletedCount++;
          } catch (e) {
            debugPrint(
                '[FileSystemService:${_moduleType.name}] Error deleting ${entity.path}: $e');
          }
        }
      }

      return deletedCount;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error clearing temp files: $e');
      return 0;
    }
  }

  /// Check if path is in temp folder
  bool isTempAudioPath(String path) {
    return path.contains(_tempAudioFolderName);
  }

  /// Check if path is a temp recording
  bool isTempRecordingPath(String path) {
    return path.contains('$_tempAudioFolderName/$_tempRecordingsSubfolder');
  }

  /// List orphaned recordings
  Future<List<String>> listOrphanedRecordings() async {
    try {
      final tempPath = await getTempAudioPath();
      final recordingsDir = Directory('$tempPath/$_tempRecordingsSubfolder');

      if (!await recordingsDir.exists()) return [];

      final orphaned = <String>[];
      await for (final entity in recordingsDir.list()) {
        if (entity is File && entity.path.endsWith('.wav')) {
          orphaned.add(entity.path);
        }
      }

      return orphaned;
    } catch (e) {
      debugPrint(
          '[FileSystemService:${_moduleType.name}] Error listing orphaned recordings: $e');
      return [];
    }
  }

  /// Delete a temp file
  Future<bool> deleteTempFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error deleting temp file: $e');
      return false;
    }
  }

  // ============================================================
  // Public API - File Operations
  // ============================================================

  /// Read file as string
  Future<String?> readFileAsString(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error reading file: $e');
      return null;
    }
  }

  /// Write string to file
  Future<bool> writeFileAsString(String filePath, String content) async {
    try {
      final file = File(filePath);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(content);
      return true;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error writing file: $e');
      return false;
    }
  }

  /// Check if file exists
  Future<bool> fileExists(String filePath) async {
    return File(filePath).exists();
  }

  /// List files in directory
  Future<List<String>> listDirectory(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];

      final files = <String>[];
      await for (final entity in dir.list()) {
        if (entity is File) {
          files.add(entity.path);
        }
      }
      return files;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error listing directory: $e');
      return [];
    }
  }

  /// Ensure directory exists
  Future<bool> ensureDirectoryExists(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return true;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error creating directory: $e');
      return false;
    }
  }

  // ============================================================
  // Public API - Permissions
  // ============================================================

  /// Check storage permission (Android)
  Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.manageExternalStorage.status;
    return status.isGranted;
  }

  /// Request storage permission (Android)
  Future<bool> requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return true;

    final result = await Permission.manageExternalStorage.request();
    if (result.isGranted) return true;

    if (result.isPermanentlyDenied) {
      debugPrint(
          '[FileSystemService:${_moduleType.name}] Storage permission permanently denied');
      await openAppSettings();
    }

    return false;
  }

  // ============================================================
  // Static Utilities
  // ============================================================

  /// Format timestamp for filename
  static String formatTimestampForFilename(DateTime timestamp) {
    return '${timestamp.year}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-'
        '${timestamp.minute.toString().padLeft(2, '0')}-'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Parse timestamp from filename
  static DateTime? parseTimestampFromFilename(String filename) {
    try {
      final regex = RegExp(r'(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})');
      final match = regex.firstMatch(filename);
      if (match == null) return null;

      return DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
      );
    } catch (e) {
      return null;
    }
  }

  /// Get month from recording ID
  static String getMonthFromRecordingId(String recordingId) {
    final regex = RegExp(r'(\d{4})-(\d{2})');
    final match = regex.firstMatch(recordingId);
    if (match != null) {
      return '${match.group(1)}-${match.group(2)}';
    }
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // Private Helpers
  // ============================================================

  Future<String> _getDefaultRootPath() async {
    final moduleName = _moduleType == ModuleType.daily ? 'Daily' : 'Chat';

    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        final preferredPath = '$home/Parachute/$moduleName';
        final preferredDir = Directory(preferredPath);
        try {
          if (!await preferredDir.exists()) {
            await preferredDir.create(recursive: true);
          }
          return preferredPath;
        } catch (e) {
          debugPrint(
              '[FileSystemService:${_moduleType.name}] Cannot access ~/Parachute/$moduleName: $e');
        }
      }
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/Parachute/$moduleName';
    }

    if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null) return '$home/Parachute/$moduleName';
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/Parachute/$moduleName';
    }

    if (Platform.isAndroid) {
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          return '${externalDir.path}/Parachute/$moduleName';
        }
      } catch (e) {
        debugPrint('[FileSystemService:${_moduleType.name}] Error getting external storage: $e');
      }
    }

    if (Platform.isIOS) {
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/Parachute/$moduleName';
    }

    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/Parachute/$moduleName';
  }

  Future<void> _ensureFolderStructure() async {
    debugPrint('[FileSystemService:${_moduleType.name}] Ensuring folder structure...');

    final root = Directory(_rootFolderPath!);
    try {
      if (!await root.exists()) {
        await root.create(recursive: true);
        debugPrint('[FileSystemService:${_moduleType.name}] Created root: ${root.path}');
      }
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Could not create root: $e');
      if (!await root.exists()) rethrow;
    }

    // Create required folders
    for (final entry in _folderConfigs.entries) {
      if (!entry.value.required) continue;

      final name = _folderNames[entry.key] ?? entry.value.defaultName;
      if (name.isEmpty) continue;

      final folder = Directory('${root.path}/$name');
      if (!await folder.exists()) {
        await folder.create(recursive: true);
        debugPrint(
            '[FileSystemService:${_moduleType.name}] Created ${entry.key} folder: ${folder.path}');
      }
    }

    debugPrint('[FileSystemService:${_moduleType.name}] Folder structure ready');
  }

  Future<void> _ensureTempFolderStructure() async {
    if (_tempAudioPath == null) return;

    final subfolders = [
      _tempRecordingsSubfolder,
      _tempPlaybackSubfolder,
      _tempSegmentsSubfolder,
    ];

    for (final subfolder in subfolders) {
      final dir = Directory('$_tempAudioPath/$subfolder');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  Future<int> _cleanupTempSubfolder(String folderPath, Duration maxAge) async {
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return 0;

      final now = DateTime.now();
      var deletedCount = 0;

      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            final age = now.difference(stat.modified);

            if (age > maxAge) {
              await entity.delete();
              deletedCount++;
            }
          } catch (e) {
            debugPrint(
                '[FileSystemService:${_moduleType.name}] Error checking temp file: $e');
          }
        }
      }

      return deletedCount;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error cleaning folder: $e');
      return 0;
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }

    await for (final entity in source.list(recursive: false)) {
      final String newPath =
          entity.path.replaceFirst(source.path, destination.path);

      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }
}

/// Internal folder configuration
class _FolderConfig {
  final String prefKey;
  final String defaultName;
  final bool required;

  const _FolderConfig({
    required this.prefKey,
    required this.defaultName,
    required this.required,
  });
}
