part of 'chat_service.dart';

/// Extension for context folder and file operations
extension ChatContextService on ChatService {
  /// Get available context files from Chat/contexts/
  ///
  /// Uses /api/ls to list files, filters for .md files,
  /// and converts to ContextFile objects.
  Future<List<ContextFile>> getContexts() async {
    try {
      final entries = await listDirectory(path: 'Chat/contexts');

      final contextFiles = <ContextFile>[];
      for (final entry in entries) {
        if (entry.isFile && entry.name.endsWith('.md')) {
          // Extract title from filename (remove .md, replace dashes with spaces, title case)
          final filename = entry.name;
          final titleFromName = filename
              .replaceAll('.md', '')
              .replaceAll('-', ' ')
              .split(' ')
              .map((w) =>
                  w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
              .join(' ');

          contextFiles.add(ContextFile(
            path: entry.relativePath,
            filename: filename,
            title: titleFromName,
            description: '', // Could enhance to read first line
            isDefault: filename == 'general-context.md',
            size: entry.size ?? 0,
            modified: entry.lastModified ?? DateTime.now(),
          ));
        }
      }

      // Sort: default first, then alphabetically
      contextFiles.sort((a, b) {
        if (a.isDefault && !b.isDefault) return -1;
        if (!a.isDefault && b.isDefault) return 1;
        return a.title.compareTo(b.title);
      });

      return contextFiles;
    } catch (e) {
      debugPrint('[ChatService] Error getting contexts: $e');
      rethrow;
    }
  }

  /// Get available context folders (folders with CLAUDE.md)
  ///
  /// Returns folders that can be selected as context for a session.
  Future<List<ContextFolder>> getContextFolders() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/contexts/folders'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get context folders: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final folders = data['folders'] as List<dynamic>? ?? [];

      return folders
          .map((f) => ContextFolder.fromJson(f as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error getting context folders: $e');
      rethrow;
    }
  }

  /// Get the context chain for selected folders
  ///
  /// Returns the full parent chain of CLAUDE.md files.
  Future<ContextChain> getContextChain(List<String> folderPaths) async {
    try {
      final foldersParam = folderPaths.join(',');
      final response = await client.get(
        Uri.parse('$baseUrl/api/contexts/chain?folders=$foldersParam'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get context chain: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ContextChain.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting context chain: $e');
      rethrow;
    }
  }

  /// Get context folders for a session
  Future<List<String>> getSessionContextFolders(String sessionId) async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/contexts/session/$sessionId'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        return []; // Session may not have contexts set
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final paths = data['folder_paths'] as List<dynamic>? ?? [];
      return paths.cast<String>();
    } catch (e) {
      debugPrint('[ChatService] Error getting session context folders: $e');
      return [];
    }
  }

  /// Set context folders for a session
  Future<void> setSessionContextFolders(
    String sessionId,
    List<String> folderPaths,
  ) async {
    try {
      final response = await client.put(
        Uri.parse('$baseUrl/api/contexts/session/$sessionId'),
        headers: defaultHeaders,
        body: jsonEncode({'folder_paths': folderPaths}),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to set session contexts: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error setting session context folders: $e');
      rethrow;
    }
  }

  /// List directory contents in the vault
  ///
  /// [path] - Relative path within vault (e.g., "", "Projects", "Code/myapp")
  /// Returns entries with metadata including hasClaudeMd for directories
  Future<List<VaultEntry>> listDirectory({String path = ''}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/ls').replace(
        queryParameters: path.isNotEmpty ? {'path': path} : null,
      );

      final response = await client.get(
        uri,
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to list directory: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final entries = data['entries'] as List<dynamic>? ?? [];

      return entries
          .map((e) => VaultEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ChatService] Error listing directory: $e');
      rethrow;
    }
  }
}
