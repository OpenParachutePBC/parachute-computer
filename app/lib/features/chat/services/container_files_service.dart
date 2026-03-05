import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/features/vault/models/file_item.dart';

/// Result of a file operation (mkdir, delete, upload).
class ContainerFileOpResult {
  final bool success;
  final String path;
  final String message;

  const ContainerFileOpResult({
    required this.success,
    required this.path,
    required this.message,
  });

  factory ContainerFileOpResult.fromJson(Map<String, dynamic> json) =>
      ContainerFileOpResult(
        success: json['success'] as bool,
        path: json['path'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );
}

/// Service for browsing and managing files in a container env's home directory.
///
/// Mirrors [ContainerEnvService] auth pattern. All paths are relative to the
/// container home directory; the server rejects traversal attempts with 403.
class ContainerFilesService {
  final String baseUrl;
  final String? apiKey;

  ContainerFilesService({required this.baseUrl, this.apiKey});

  Map<String, String> get _headers => {
        'User-Agent': 'Parachute-Chat/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };

  /// List directory contents for [slug] at relative [path] (default: home root).
  Future<List<FileItem>> listFiles(
    String slug, {
    String path = '',
    bool includeHidden = false,
  }) async {
    final params = <String, String>{};
    if (path.isNotEmpty) params['path'] = path;
    if (includeHidden) params['includeHidden'] = 'true';

    final uri = Uri.parse('$baseUrl/api/projects/$slug/files')
        .replace(queryParameters: params.isNotEmpty ? params : null);

    final response = await http.get(uri, headers: _headers).timeout(
      const Duration(seconds: 15),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to list container files: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final entries = data['entries'] as List<dynamic>;

    final items = entries.map((e) {
      final entry = e as Map<String, dynamic>;
      final isDir = entry['isDirectory'] as bool;
      final name = entry['name'] as String;
      final entryPath = entry['path'] as String;
      final size = entry['size'] as int?;
      final lastModified = entry['lastModified'] as String?;

      return FileItem(
        name: name,
        path: entryPath,
        type: isDir ? FileItemType.folder : _fileTypeFor(name),
        sizeBytes: size,
        modified: lastModified != null ? DateTime.tryParse(lastModified) : null,
      );
    }).toList();

    // Folders first, then alphabetically by name (case-insensitive).
    items.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
  }

  /// Download raw bytes for a file at relative [path].
  Future<Uint8List> downloadFile(String slug, String path) async {
    final uri = Uri.parse('$baseUrl/api/projects/$slug/files/download')
        .replace(queryParameters: {'path': path});

    final response = await http.get(uri, headers: _headers).timeout(
      const Duration(seconds: 60),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to download file: ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  /// Upload [files] into [slug]'s home directory at optional [uploadPath].
  Future<List<ContainerFileOpResult>> uploadFiles(
    String slug,
    List<PlatformFile> files, {
    String uploadPath = '',
  }) async {
    final params = <String, String>{};
    if (uploadPath.isNotEmpty) params['path'] = uploadPath;

    final uri = Uri.parse('$baseUrl/api/projects/$slug/files/upload')
        .replace(queryParameters: params.isNotEmpty ? params : null);

    final request = http.MultipartRequest('POST', uri);
    if (apiKey != null && apiKey!.isNotEmpty) {
      request.headers['X-API-Key'] = apiKey!;
    }

    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      request.files.add(http.MultipartFile.fromBytes(
        'files',
        bytes,
        filename: file.name,
      ));
    }

    final streamed = await request.send().timeout(const Duration(minutes: 5));
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode != 200 && streamed.statusCode != 201) {
      throw Exception('Upload failed: ${streamed.statusCode} $body');
    }

    final list = jsonDecode(body) as List<dynamic>;
    return list
        .map((e) => ContainerFileOpResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Create a directory at relative [path] within [slug]'s home.
  Future<ContainerFileOpResult> mkdir(String slug, String path) async {
    final uri = Uri.parse('$baseUrl/api/projects/$slug/files/mkdir')
        .replace(queryParameters: {'path': path});

    final response = await http.post(uri, headers: _headers).timeout(
      const Duration(seconds: 15),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('mkdir failed: ${response.statusCode} ${response.body}');
    }

    return ContainerFileOpResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Delete a file or directory at relative [path] within [slug]'s home.
  Future<ContainerFileOpResult> delete(String slug, String path) async {
    final uri = Uri.parse('$baseUrl/api/projects/$slug/files')
        .replace(queryParameters: {'path': path});

    final response = await http.delete(uri, headers: _headers).timeout(
      const Duration(seconds: 30),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Delete failed: ${response.statusCode} ${response.body}');
    }

    if (response.statusCode == 204 || response.body.isEmpty) {
      return ContainerFileOpResult(success: true, path: path, message: 'Deleted');
    }

    return ContainerFileOpResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static const _imageExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'bmp',
  };

  static const _audioExtensions = {
    'mp3', 'wav', 'm4a', 'ogg', 'flac', 'opus', 'aac',
  };

  static const _textExtensions = {
    'json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf',
    'dart', 'js', 'ts', 'jsx', 'tsx', 'py', 'rb', 'go', 'rs', 'java', 'kt',
    'swift', 'c', 'cpp', 'h', 'hpp', 'cs', 'php', 'sh', 'bash', 'zsh', 'fish',
    'html', 'htm', 'css', 'scss', 'sass', 'less', 'vue', 'svelte',
    'xml', 'csv', 'tsv', 'sql',
    'txt', 'log', 'env', 'gitignore', 'dockerignore', 'editorconfig',
    'rst', 'tex', 'bib',
  };

  FileItemType _fileTypeFor(String name) {
    final ext = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    if (ext == 'md' || ext == 'markdown') return FileItemType.markdown;
    if (_imageExtensions.contains(ext)) return FileItemType.image;
    if (_audioExtensions.contains(ext)) return FileItemType.audio;
    if (_textExtensions.contains(ext)) return FileItemType.text;
    return FileItemType.other;
  }
}
