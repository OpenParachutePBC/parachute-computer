part of 'chat_service.dart';

/// Extension for vault file operations
extension ChatVaultService on ChatService {
  /// Read a file from the vault via the server API
  ///
  /// [relativePath] - Path relative to vault root (e.g., 'Chat/contexts/general-context.md')
  /// Returns file content and metadata, or null if not found
  Future<VaultFileContent?> readFile(String relativePath) async {
    try {
      final uri = Uri.parse('$baseUrl/api/read').replace(
        queryParameters: {'path': relativePath},
      );

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to read file: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return VaultFileContent.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error reading file $relativePath: $e');
      rethrow;
    }
  }

  /// Write a file to the vault via the server API
  ///
  /// [relativePath] - Path relative to vault root (e.g., 'Chat/contexts/my-context.md')
  /// [content] - The file content to write
  Future<void> writeFile(String relativePath, String content) async {
    try {
      final response = await client.put(
        Uri.parse('$baseUrl/api/write'),
        headers: defaultHeaders,
        body: jsonEncode({
          'path': relativePath,
          'content': content,
        }),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to write file: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error writing file $relativePath: $e');
      rethrow;
    }
  }
}

/// Content read from a vault file via API
class VaultFileContent {
  final String path;
  final String content;
  final int size;
  final DateTime lastModified;

  const VaultFileContent({
    required this.path,
    required this.content,
    required this.size,
    required this.lastModified,
  });

  factory VaultFileContent.fromJson(Map<String, dynamic> json) {
    return VaultFileContent(
      path: json['path'] as String,
      content: json['content'] as String,
      size: json['size'] as int,
      lastModified: DateTime.parse(json['lastModified'] as String),
    );
  }
}
