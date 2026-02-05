import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'package:parachute/features/vault/models/file_item.dart';

/// Exception thrown when directory listing fails due to permissions
class DirectoryPermissionException implements Exception {
  final String path;
  final String message;

  DirectoryPermissionException(this.path, this.message);

  @override
  String toString() => message;
}

/// Service for browsing the vault folder structure
class FileBrowserService {
  final FileSystemService _fileSystem;

  FileBrowserService(this._fileSystem);

  /// Get the initial path (vault root)
  Future<String> getInitialPath() async {
    return _fileSystem.getRootPath();
  }

  /// Check if the given path is the vault root
  Future<bool> isAtRoot(String path) async {
    final rootPath = await _fileSystem.getRootPath();
    return path == rootPath;
  }

  /// Get the parent path of the given path
  String getParentPath(String path) {
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return path.substring(0, lastSlash);
  }

  /// Get a display-friendly version of the path
  Future<String> getDisplayPath(String path) async {
    final rootPath = await _fileSystem.getRootPath();

    if (path == rootPath) {
      return await _fileSystem.getRootPathDisplay();
    }

    // Show path relative to root with ~ prefix
    final rootDisplay = await _fileSystem.getRootPathDisplay();
    if (path.startsWith(rootPath)) {
      return rootDisplay + path.substring(rootPath.length);
    }

    return path;
  }

  /// Get the folder name from a path
  String getFolderName(String path) {
    return path.split('/').last;
  }

  /// List contents of a folder
  /// Returns items sorted: folders first, then files, alphabetically
  /// Set [includeHidden] to true to show files/folders starting with '.'
  Future<List<FileItem>> listFolder(String path, {bool includeHidden = false}) async {
    try {
      final dir = Directory(path);
      final exists = await dir.exists();
      debugPrint('[FileBrowserService] Directory exists check for $path: $exists');

      if (!exists) {
        debugPrint('[FileBrowserService] Directory does not exist: $path');
        return [];
      }

      final items = <FileItem>[];
      int entityCount = 0;
      int skippedCount = 0;

      try {
        await for (final entity in dir.list()) {
          entityCount++;
          try {
            final stat = await entity.stat();
            final isDirectory = entity is Directory;

            // Skip hidden files/folders (starting with .) unless includeHidden is true
            final name = entity.path.split('/').last;
            if (!includeHidden && name.startsWith('.')) {
              skippedCount++;
              continue;
            }

            items.add(FileItem.fromPath(
              entity.path,
              isDirectory: isDirectory,
              modified: stat.modified,
              sizeBytes: isDirectory ? null : stat.size,
            ));
          } catch (e) {
            debugPrint('[FileBrowserService] Error reading ${entity.path}: $e');
          }
        }
      } catch (e) {
        debugPrint('[FileBrowserService] Error iterating directory $path: $e');
      }

      debugPrint('[FileBrowserService] Raw entities: $entityCount, skipped: $skippedCount, visible: ${items.length}');

      // On Android, if directory exists but we can't list contents, it's likely a permission issue
      if (entityCount == 0 && Platform.isAndroid) {
        final rootPath = await _fileSystem.getRootPath();
        // Only show error if this is a subfolder (not root) - root might genuinely be empty
        if (path != rootPath) {
          debugPrint('[FileBrowserService] Android permission issue detected for $path');
          throw DirectoryPermissionException(
            path,
            'Cannot access folder contents on Android.\n\n'
            'Please grant storage permission in Settings → Storage.',
          );
        }
      }

      // Sort: folders first, then alphabetically by name
      items.sort((a, b) {
        if (a.isFolder && !b.isFolder) return -1;
        if (!a.isFolder && b.isFolder) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      debugPrint('[FileBrowserService] Listed ${items.length} items in $path');
      return items;
    } on DirectoryPermissionException {
      rethrow; // Let permission exceptions propagate to show user-friendly message
    } catch (e, stackTrace) {
      debugPrint('[FileBrowserService] Error listing folder $path: $e');
      debugPrint('[FileBrowserService] Stack trace: $stackTrace');
      return [];
    }
  }

  /// Delete a file or folder
  /// For folders, deletes recursively
  Future<void> deleteItem(String path) async {
    try {
      // First check if it's within the vault
      if (!await isWithinVault(path)) {
        throw Exception('Cannot delete items outside the vault');
      }

      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(path);
        await dir.delete(recursive: true);
        debugPrint('[FileBrowserService] Deleted directory: $path');
      } else if (type == FileSystemEntityType.file) {
        final file = File(path);
        await file.delete();
        debugPrint('[FileBrowserService] Deleted file: $path');
      } else {
        throw Exception('Item does not exist');
      }
    } catch (e) {
      debugPrint('[FileBrowserService] Error deleting $path: $e');
      rethrow;
    }
  }

  /// Check if a path is within the vault
  Future<bool> isWithinVault(String path) async {
    final rootPath = await _fileSystem.getRootPath();
    return path.startsWith(rootPath);
  }

  /// Read file contents as string (for markdown viewing)
  Future<String?> readFileAsString(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('[FileBrowserService] File does not exist: $path');
        return null;
      }

      // Security: Verify path doesn't escape vault via symlinks
      final resolvedPath = await file.resolveSymbolicLinks();
      final rootPath = await _fileSystem.getRootPath();
      if (!resolvedPath.startsWith(rootPath)) {
        debugPrint('[FileBrowserService] Security: Path escapes vault boundary: $resolvedPath');
        throw Exception('Access denied: Path escapes vault boundary');
      }

      return await file.readAsString();
    } catch (e) {
      debugPrint('[FileBrowserService] Error reading file $path: $e');
      return null;
    }
  }

  /// Write content to a file
  /// Creates the file if it doesn't exist
  Future<void> writeFile(String path, String content) async {
    try {
      // Safety check: must be within vault
      if (!await isWithinVault(path)) {
        throw Exception('Cannot write files outside the vault');
      }

      final file = File(path);
      await file.writeAsString(content);
      debugPrint('[FileBrowserService] Wrote ${content.length} chars to: $path');
    } catch (e) {
      debugPrint('[FileBrowserService] Error writing file $path: $e');
      rethrow;
    }
  }

  /// Create a new file with initial content
  /// Returns the path of the created file
  Future<String> createFile(String directory, String filename, String content) async {
    try {
      // Safety check: must be within vault
      if (!await isWithinVault(directory)) {
        throw Exception('Cannot create files outside the vault');
      }

      final path = '$directory/$filename';
      final file = File(path);

      if (await file.exists()) {
        throw Exception('File already exists: $filename');
      }

      await file.writeAsString(content);
      debugPrint('[FileBrowserService] Created file: $path');
      return path;
    } catch (e) {
      debugPrint('[FileBrowserService] Error creating file: $e');
      rethrow;
    }
  }
}
