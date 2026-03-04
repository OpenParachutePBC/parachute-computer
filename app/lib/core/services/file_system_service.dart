import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

/// Module type for the file system service
enum ModuleType {
  /// Daily module - ~/Parachute with 'Daily' subfolder (offline-capable, synced)
  daily,

  /// Chat module - ~/Parachute with 'Chat' subfolder (server-managed)
  chat,
}

/// Unified file system service for Parachute
///
/// Manages modular vault structures within a single Parachute vault:
/// - ~/Parachute/Daily/ - Daily journals, assets, reflections (local, synced)
/// - ~/Parachute/Chat/ - Chat sessions, contexts, artifacts (server-managed)
///
/// The vault root (~/Parachute) is shared across modules, with each module
/// having its own subfolder. This allows users to configure one vault location
/// while keeping module data organized.
///
/// Philosophy: Files are the source of truth, databases are indexes.
class FileSystemService {
  // ============================================================
  // Instance Management - Riverpod-managed instances
  // ============================================================

  final ModuleType _moduleType;

  /// Create a FileSystemService for the given module type
  ///
  /// NOTE: Don't call this directly. Use the fileSystemServiceProvider instead:
  ///   ref.watch(fileSystemServiceProvider(ModuleType.daily))
  ///
  /// The static factory methods (daily(), chat(), forModule()) are deprecated
  /// and should not be used in new code.
  FileSystemService(this._moduleType);

  /// Deprecated: Use fileSystemServiceProvider(ModuleType.daily) instead
  @Deprecated('Use fileSystemServiceProvider(ModuleType.daily) instead')
  factory FileSystemService.daily() => FileSystemService(ModuleType.daily);

  /// Deprecated: Use fileSystemServiceProvider(ModuleType.chat) instead
  @Deprecated('Use fileSystemServiceProvider(ModuleType.chat) instead')
  factory FileSystemService.chat() => FileSystemService(ModuleType.chat);

  /// Deprecated: Use fileSystemServiceProvider(moduleType) instead
  @Deprecated('Use fileSystemServiceProvider(moduleType) instead')
  factory FileSystemService.forModule(ModuleType moduleType) => FileSystemService(moduleType);

  // ============================================================
  // One-time migrations
  // ============================================================

  static const _migrationV1Key = 'parachute_fss_migration_v1';
  static const _migrationV2Key = 'parachute_fss_migration_v2';

  /// Run one-time SharedPreferences migrations.
  ///
  /// REQUIRES: [WidgetsFlutterBinding.ensureInitialized()] (or equivalent)
  /// must have been called before this method. On Android/iOS,
  /// [SharedPreferences.getInstance()] will throw if the binding is not ready.
  ///
  /// Call from [main()] after binding initialization, before [runApp()].
  /// Safe to call on every launch — sentinel keys ensure each migration
  /// runs exactly once.
  static Future<void> runMigrations() async {
    final prefs = await SharedPreferences.getInstance();

    // v1: clear stale daily vault-path keys (PR #173 moved audio server-side)
    if (prefs.getBool(_migrationV1Key) != true) {
      const v1Keys = [
        'parachute_daily_vault_path',
        'parachute_daily_root_path',
        'parachute_daily_secure_bookmark',
        'parachute_daily_user_configured',
        'parachute_daily_module_folder',
        'parachute_daily_journals_folder',
        'parachute_daily_assets_folder',
        'parachute_daily_reflections_folder',
        'parachute_daily_chatlog_folder',
      ];
      for (final key in v1Keys) {
        await prefs.remove(key);
      }
      await prefs.setBool(_migrationV1Key, true);
      debugPrint('[FileSystemService] runMigrations: v1 complete');
    }

    // v2: clear chat vault-path keys and global vault path keys now that
    // vault path is no longer user-configurable (Phase 3 of #172).
    if (prefs.getBool(_migrationV2Key) != true) {
      const v2Keys = [
        // Chat module vault-path keys
        'parachute_chat_vault_path',
        'parachute_chat_root_path',
        'parachute_chat_secure_bookmark',
        'parachute_chat_user_configured',
        'parachute_chat_module_folder',
        'parachute_chat_sessions_folder',
        'parachute_chat_assets_folder',
        'parachute_chat_artifacts_folder',
        'parachute_chat_contexts_folder',
        'parachute_chat_imports_folder',
        // Global vault path keys (VaultPathNotifier)
        'parachute_vault_path',
        'parachute_server_vault_path',
      ];
      for (final key in v2Keys) {
        await prefs.remove(key);
      }
      await prefs.setBool(_migrationV2Key, true);
      debugPrint('[FileSystemService] runMigrations: v2 complete');
    }
  }

  // ============================================================
  // Constants
  // ============================================================

  // SharedPreferences key prefix (still used for subfolder name keys)
  String get _keyPrefix => 'parachute_${_moduleType.name}_';

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

  /// The vault root path (e.g., ~/Parachute)
  String? _vaultPath;

  /// The module folder name within the vault (e.g., "Daily" or "Chat")
  String? _moduleFolderName;

  String? _tempAudioPath;
  final Map<String, String> _folderNames = {};
  bool _isInitialized = false;
  Future<void>? _initializationFuture;

  // ============================================================
  // Folder Configuration by Module
  // ============================================================

  /// Get the default module folder name (Daily or Chat)
  String get _defaultModuleFolderName =>
      _moduleType == ModuleType.daily ? 'Daily' : 'Chat';

  /// Get default folder configuration for this module
  /// Note: These are subfolders within the module folder (e.g., Daily/journals)
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

      // Vault path is no longer user-configurable — always use the platform default.
      // (SharedPreferences vault keys were cleared by runMigrations() v2.)
      _vaultPath = await _getDefaultVaultPath();
      _moduleFolderName = _defaultModuleFolderName;
      debugPrint('[FileSystemService:${_moduleType.name}] vault: $_vaultPath, module folder: $_moduleFolderName');

      // Load subfolder names from preferences (still customisable per-module)
      final prefs = await SharedPreferences.getInstance();
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

  /// Get the full module path (vault + module folder)
  String _getModulePath() {
    if (_moduleFolderName == null || _moduleFolderName!.isEmpty) {
      return _vaultPath!;
    }
    return '$_vaultPath/$_moduleFolderName';
  }

  // ============================================================
  // Public API - Path Access
  // ============================================================

  /// Get the module root folder path (e.g., ~/Parachute/Daily)
  /// This is the path where all module data is stored.
  Future<String> getRootPath() async {
    await initialize();
    return _getModulePath();
  }

  /// Get the vault root path (e.g., ~/Parachute)
  /// This is the parent folder that contains all modules.
  Future<String> getVaultPath() async {
    await initialize();
    return _vaultPath!;
  }

  /// Get the module folder name (e.g., "Daily" or "Chat")
  Future<String> getModuleFolderName() async {
    await initialize();
    return _moduleFolderName ?? _defaultModuleFolderName;
  }

  /// Get user-friendly vault path display (with ~ for home)
  Future<String> getVaultPathDisplay() async {
    final path = await getVaultPath();
    return _formatPathForDisplay(path);
  }

  /// Get user-friendly module root path display (with ~ for home)
  Future<String> getRootPathDisplay() async {
    final path = await getRootPath();
    return _formatPathForDisplay(path);
  }

  /// Format a path for display (replace home with ~)
  String _formatPathForDisplay(String path) {
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null && path.startsWith(home)) {
        return path.replaceFirst(home, '~');
      }
    }
    return path;
  }

  /// Set the vault root path in-memory (no longer persisted to SharedPreferences).
  ///
  /// The vault path is not user-configurable; this method exists for callers that
  /// previously needed to override the path for a session. The path is only
  /// held in memory and reverts to the platform default on next app launch.
  Future<bool> setVaultPath(String vaultPath, {bool migrateFiles = true}) async {
    try {
      debugPrint('[FileSystemService:${_moduleType.name}] setVaultPath: $vaultPath (in-memory only)');

      _moduleFolderName ??= _defaultModuleFolderName;

      final oldModulePath = _vaultPath != null ? _getModulePath() : null;

      // Ensure vault and module directories exist
      final vaultDir = Directory(vaultPath);
      if (!await vaultDir.exists()) {
        await vaultDir.create(recursive: true);
      }

      final newModulePath = _moduleFolderName != null && _moduleFolderName!.isNotEmpty
          ? '$vaultPath/$_moduleFolderName'
          : vaultPath;
      final newModuleDir = Directory(newModulePath);
      if (!await newModuleDir.exists()) {
        await newModuleDir.create(recursive: true);
      }

      // Migrate files if requested
      if (migrateFiles && oldModulePath != null && oldModulePath != newModulePath) {
        final oldDir = Directory(oldModulePath);
        if (await oldDir.exists()) {
          debugPrint('[FileSystemService:${_moduleType.name}] Migrating files $oldModulePath → $newModulePath');
          await _copyDirectory(oldDir, newModuleDir);
        }
      }

      _vaultPath = vaultPath;
      await _ensureFolderStructure();
      return true;
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Error setting vault path: $e');
      return false;
    }
  }

  /// Set custom root path with optional file migration (legacy API, calls setVaultPath)
  @Deprecated('Use setVaultPath instead for clarity')
  Future<bool> setRootPath(String path, {bool migrateFiles = true}) async {
    // For backwards compatibility: if the path ends with the module folder name,
    // extract the vault path. Otherwise, treat as vault path.
    final moduleSuffix = '/$_defaultModuleFolderName';
    String vaultPath;
    if (path.endsWith(moduleSuffix)) {
      vaultPath = path.substring(0, path.length - moduleSuffix.length);
    } else {
      vaultPath = path;
    }
    return setVaultPath(vaultPath, migrateFiles: migrateFiles);
  }

  /// Reset to default path (in-memory only — vault path is no longer persisted).
  Future<bool> resetToDefaultPath() async {
    final defaultVaultPath = await _getDefaultVaultPath();
    _moduleFolderName = _defaultModuleFolderName;
    return setVaultPath(defaultVaultPath, migrateFiles: false);
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
  // Public API - Assets (Date-based organization: assets/YYYY-MM-DD/)
  // ============================================================

  /// Get date folder path for assets (YYYY-MM-DD)
  Future<String> getAssetsDatePath(DateTime timestamp) async {
    final assetsPath = await getFolderPath('assets');
    final date = '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}';
    return '$assetsPath/$date';
  }

  /// Get month folder path for assets (YYYY-MM) - DEPRECATED, use getAssetsDatePath
  @Deprecated('Use getAssetsDatePath for date-based organization')
  Future<String> getAssetsMonthPath(DateTime timestamp) async {
    return getAssetsDatePath(timestamp);
  }

  /// Ensure date folder exists for assets
  Future<String> ensureAssetsDateFolderExists(DateTime timestamp) async {
    final datePath = await getAssetsDatePath(timestamp);
    final dateDir = Directory(datePath);
    if (!await dateDir.exists()) {
      await dateDir.create(recursive: true);
      debugPrint('[FileSystemService:${_moduleType.name}] Created assets folder: $datePath');
    }
    return datePath;
  }

  /// Ensure month folder exists - DEPRECATED, use ensureAssetsDateFolderExists
  @Deprecated('Use ensureAssetsDateFolderExists for date-based organization')
  Future<String> ensureAssetsMonthFolderExists(DateTime timestamp) async {
    return ensureAssetsDateFolderExists(timestamp);
  }

  /// Generate unique asset filename (now without date prefix since folder has date)
  String generateAssetFilename(
      DateTime timestamp, String type, String extension) {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}';
    return '${time}_$type.$extension';
  }

  /// Get full path for new asset
  Future<String> getNewAssetPath(
      DateTime timestamp, String type, String extension) async {
    final datePath = await ensureAssetsDateFolderExists(timestamp);
    final filename = generateAssetFilename(timestamp, type, extension);
    return '$datePath/$filename';
  }

  /// Get relative path from root to asset
  String getAssetRelativePath(DateTime timestamp, String filename) {
    final date = '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}';
    final assetsName = _folderNames['assets'] ?? 'assets';
    return '$assetsName/$date/$filename';
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

  /// Get the default vault root path (~).
  /// The module subfolder (Daily/Chat) is handled separately via folder config.
  /// On macOS/Linux, defaults to home directory for the "operating at root" experience.
  /// On mobile platforms, uses app-specific storage with Parachute subfolder.
  Future<String> _getDefaultVaultPath() async {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        final homeDir = Directory(home);
        try {
          // Verify home directory is accessible
          if (await homeDir.exists()) {
            debugPrint('[FileSystemService:${_moduleType.name}] Using home path: $home');
            return home;
          }
        } catch (e) {
          debugPrint(
              '[FileSystemService:${_moduleType.name}] Cannot access home: $e');
        }
      }
      // Fall back to app container
      final appDir = await getApplicationDocumentsDirectory();
      debugPrint('[FileSystemService:${_moduleType.name}] Using container path: ${appDir.path}');
      return appDir.path;
    }

    if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null) return home;
      final appDir = await getApplicationDocumentsDirectory();
      return appDir.path;
    }

    if (Platform.isAndroid) {
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          return '${externalDir.path}/Parachute';
        }
      } catch (e) {
        debugPrint('[FileSystemService:${_moduleType.name}] Error getting external storage: $e');
      }
    }

    if (Platform.isIOS) {
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/Parachute';
    }

    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/Parachute';
  }

  Future<void> _ensureFolderStructure() async {
    debugPrint('[FileSystemService:${_moduleType.name}] Ensuring folder structure...');

    // Ensure vault root exists
    final vault = Directory(_vaultPath!);
    try {
      if (!await vault.exists()) {
        await vault.create(recursive: true);
        debugPrint('[FileSystemService:${_moduleType.name}] Created vault: ${vault.path}');
      }
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Could not create vault: $e');
      if (!await vault.exists()) rethrow;
    }

    // Ensure module folder exists (if we have one)
    final modulePath = _getModulePath();
    final moduleDir = Directory(modulePath);
    try {
      if (!await moduleDir.exists()) {
        await moduleDir.create(recursive: true);
        debugPrint('[FileSystemService:${_moduleType.name}] Created module folder: $modulePath');
      }
    } catch (e) {
      debugPrint('[FileSystemService:${_moduleType.name}] Could not create module folder: $e');
      if (!await moduleDir.exists()) rethrow;
    }

    // Create required subfolders within module folder
    for (final entry in _folderConfigs.entries) {
      if (!entry.value.required) continue;

      final name = _folderNames[entry.key] ?? entry.value.defaultName;
      if (name.isEmpty) continue;

      final folder = Directory('$modulePath/$name');
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
