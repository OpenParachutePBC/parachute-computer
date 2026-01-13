import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/features/vault/models/file_item.dart';

/// Service for browsing the vault folder structure via the remote Base server API
class RemoteFileBrowserService {
  final String baseUrl;

  RemoteFileBrowserService({required this.baseUrl});

  /// Get the initial path (vault root - empty string for remote)
  String getInitialPath() => '';

  /// Check if the given path is the vault root
  bool isAtRoot(String path) => path.isEmpty;

  /// Get the parent path of the given path
  String getParentPath(String path) {
    if (path.isEmpty) return '';
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return '';
    return path.substring(0, lastSlash);
  }

  /// Get a display-friendly version of the path
  String getDisplayPath(String path) {
    if (path.isEmpty) return '~/Parachute';
    return '~/Parachute/$path';
  }

  /// Get the folder name from a path
  String getFolderName(String path) {
    if (path.isEmpty) return 'Vault';
    return path.split('/').last;
  }

  /// List contents of a folder via the remote API
  /// Returns items sorted: folders first, then files, alphabetically
  Future<List<FileItem>> listFolder(String path) async {
    try {
      final uri = Uri.parse('$baseUrl/api/ls').replace(
        queryParameters: path.isNotEmpty ? {'path': path} : null,
      );

      debugPrint('[RemoteFileBrowser] Fetching: $uri');

      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Connection timeout');
        },
      );

      if (response.statusCode != 200) {
        debugPrint('[RemoteFileBrowser] Error ${response.statusCode}: ${response.body}');
        throw Exception('Server error: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final entries = data['entries'] as List<dynamic>;

      final items = entries.map((entry) {
        final e = entry as Map<String, dynamic>;
        final isDir = e['isDirectory'] as bool;
        final relativePath = e['relativePath'] as String;
        final name = e['name'] as String;
        final lastModified = e['lastModified'] as String?;
        final size = e['size'] as int?;

        return FileItem(
          name: name,
          path: relativePath, // Use relative path for navigation
          type: isDir
              ? FileItemType.folder
              : _getFileType(name),
          modified: lastModified != null ? DateTime.tryParse(lastModified) : null,
          sizeBytes: size,
        );
      }).toList();

      // Sort: folders first, then alphabetically
      items.sort((a, b) {
        if (a.isFolder && !b.isFolder) return -1;
        if (!a.isFolder && b.isFolder) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      debugPrint('[RemoteFileBrowser] Listed ${items.length} items in "$path"');
      return items;
    } catch (e) {
      debugPrint('[RemoteFileBrowser] Error listing folder "$path": $e');
      rethrow;
    }
  }

  /// Read file contents as string (for markdown viewing)
  Future<String?> readFile(String path) async {
    try {
      final uri = Uri.parse('$baseUrl/api/read').replace(
        queryParameters: {'path': path},
      );

      debugPrint('[RemoteFileBrowser] Reading: $uri');

      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) {
        debugPrint('[RemoteFileBrowser] Error reading file: ${response.statusCode}');
        return null;
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['content'] as String?;
    } catch (e) {
      debugPrint('[RemoteFileBrowser] Error reading file "$path": $e');
      return null;
    }
  }

  /// Write content to a file via the remote API
  Future<bool> writeFile(String path, String content) async {
    try {
      final uri = Uri.parse('$baseUrl/api/write');

      debugPrint('[RemoteFileBrowser] Writing: $path');

      final response = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'path': path,
          'content': content,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('[RemoteFileBrowser] Error writing file: ${response.statusCode}');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[RemoteFileBrowser] Error writing file "$path": $e');
      return false;
    }
  }

  FileItemType _getFileType(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'md':
      case 'markdown':
        return FileItemType.markdown;
      case 'mp3':
      case 'wav':
      case 'm4a':
      case 'ogg':
      case 'flac':
        return FileItemType.audio;
      default:
        return FileItemType.other;
    }
  }
}
