import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/chat_session.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'para_id_service.dart';

/// Result of importing a single conversation
class ImportedConversation {
  final String originalId;
  final String title;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<ImportedMessage> messages;
  final ChatSource source;

  const ImportedConversation({
    required this.originalId,
    required this.title,
    required this.createdAt,
    this.updatedAt,
    required this.messages,
    required this.source,
  });

  int get messageCount => messages.length;
}

/// A message from an imported conversation
class ImportedMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime? timestamp;

  const ImportedMessage({
    required this.role,
    required this.content,
    this.timestamp,
  });
}

/// Result of an import operation
class ImportResult {
  final int totalConversations;
  final int importedCount;
  final int skippedCount;
  final List<String> errors;
  final List<ChatSession> sessions;

  const ImportResult({
    required this.totalConversations,
    required this.importedCount,
    required this.skippedCount,
    required this.errors,
    required this.sessions,
  });

  bool get hasErrors => errors.isNotEmpty;
  bool get isSuccess => importedCount > 0 && errors.isEmpty;
}

/// Service for importing chat history from external sources
///
/// Supports:
/// - ChatGPT (conversations.json from data export)
/// - Claude (JSON export from claude.ai)
class ChatImportService {
  final FileSystemService _fileSystem;
  static const _uuid = Uuid();

  ChatImportService(this._fileSystem);

  /// Parse a ChatGPT export file and return conversations
  ///
  /// ChatGPT exports contain a conversations.json with a complex nested structure.
  /// Each conversation has a mapping of message IDs to message objects.
  Future<List<ImportedConversation>> parseChatGPTExport(String jsonContent) async {
    try {
      final data = jsonDecode(jsonContent);

      if (data is! List) {
        throw FormatException('Expected array of conversations');
      }

      final conversations = <ImportedConversation>[];

      for (final conv in data) {
        try {
          final imported = _parseChatGPTConversation(conv as Map<String, dynamic>);
          if (imported != null && imported.messages.isNotEmpty) {
            conversations.add(imported);
          }
        } catch (e) {
          debugPrint('[ChatImport] Error parsing ChatGPT conversation: $e');
        }
      }

      debugPrint('[ChatImport] Parsed ${conversations.length} ChatGPT conversations');
      return conversations;
    } catch (e) {
      debugPrint('[ChatImport] Error parsing ChatGPT export: $e');
      rethrow;
    }
  }

  /// Parse a single ChatGPT conversation
  ImportedConversation? _parseChatGPTConversation(Map<String, dynamic> conv) {
    final id = conv['id'] as String? ?? conv['conversation_id'] as String?;
    if (id == null) return null;

    final title = conv['title'] as String? ?? 'Untitled Conversation';

    // Parse timestamps
    final createTime = conv['create_time'];
    final updateTime = conv['update_time'];
    final createdAt = _parseUnixTimestamp(createTime) ?? DateTime.now();
    final updatedAt = _parseUnixTimestamp(updateTime);

    // Parse messages from the mapping structure
    final mapping = conv['mapping'] as Map<String, dynamic>?;
    if (mapping == null) return null;

    final messages = <ImportedMessage>[];

    // ChatGPT uses a tree structure with parent/children references
    // We need to traverse it in order
    final messageOrder = <String>[];
    String? currentId = conv['current_node'] as String?;

    // Build the path from root to current node
    if (currentId != null) {
      final visited = <String>{};
      while (currentId != null && !visited.contains(currentId)) {
        visited.add(currentId);
        messageOrder.insert(0, currentId);
        final node = mapping[currentId] as Map<String, dynamic>?;
        currentId = node?['parent'] as String?;
      }
    }

    // If we couldn't trace the path, just iterate all messages
    if (messageOrder.isEmpty) {
      messageOrder.addAll(mapping.keys);
    }

    for (final msgId in messageOrder) {
      final node = mapping[msgId] as Map<String, dynamic>?;
      if (node == null) continue;

      final message = node['message'] as Map<String, dynamic>?;
      if (message == null) continue;

      final author = message['author'] as Map<String, dynamic>?;
      final roleStr = author?['role'] as String?;

      // Only include user and assistant messages
      if (roleStr != 'user' && roleStr != 'assistant') continue;
      final role = roleStr!; // Safe: we just checked it's user or assistant

      final content = message['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List<dynamic>?;

      if (parts == null || parts.isEmpty) continue;

      // Combine all text parts
      final textContent = parts
          .whereType<String>()
          .join('\n')
          .trim();

      if (textContent.isEmpty) continue;

      final msgCreateTime = message['create_time'];
      final msgTimestamp = _parseUnixTimestamp(msgCreateTime);

      messages.add(ImportedMessage(
        role: role,
        content: textContent,
        timestamp: msgTimestamp,
      ));
    }

    if (messages.isEmpty) return null;

    return ImportedConversation(
      originalId: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      source: ChatSource.chatgpt,
    );
  }

  /// Parse a Claude export file and return conversations
  ///
  /// Claude exports are simpler with a direct messages array.
  Future<List<ImportedConversation>> parseClaudeExport(String jsonContent) async {
    try {
      final data = jsonDecode(jsonContent);

      // Claude export might be a single conversation or array
      final conversations = <ImportedConversation>[];

      if (data is List) {
        for (final conv in data) {
          try {
            final imported = _parseClaudeConversation(conv as Map<String, dynamic>);
            if (imported != null && imported.messages.isNotEmpty) {
              conversations.add(imported);
            }
          } catch (e) {
            debugPrint('[ChatImport] Error parsing Claude conversation: $e');
          }
        }
      } else if (data is Map<String, dynamic>) {
        // Might be wrapped in a container
        final chats = data['conversations'] as List<dynamic>? ??
            data['chats'] as List<dynamic>? ??
            [data];

        for (final conv in chats) {
          try {
            final imported = _parseClaudeConversation(conv as Map<String, dynamic>);
            if (imported != null && imported.messages.isNotEmpty) {
              conversations.add(imported);
            }
          } catch (e) {
            debugPrint('[ChatImport] Error parsing Claude conversation: $e');
          }
        }
      }

      debugPrint('[ChatImport] Parsed ${conversations.length} Claude conversations');
      return conversations;
    } catch (e) {
      debugPrint('[ChatImport] Error parsing Claude export: $e');
      rethrow;
    }
  }

  /// Parse a single Claude conversation
  ImportedConversation? _parseClaudeConversation(Map<String, dynamic> conv) {
    final id = conv['uuid'] as String? ??
        conv['id'] as String? ??
        conv['conversation_id'] as String?;
    if (id == null) return null;

    final title = conv['name'] as String? ??
        conv['title'] as String? ??
        'Untitled Conversation';

    // Parse timestamps
    final createdAt = _parseIsoTimestamp(conv['created_at'] as String?) ??
        _parseIsoTimestamp(conv['createdAt'] as String?) ??
        DateTime.now();
    final updatedAt = _parseIsoTimestamp(conv['updated_at'] as String?) ??
        _parseIsoTimestamp(conv['updatedAt'] as String?);

    // Parse messages
    final chatMessages = conv['chat_messages'] as List<dynamic>? ??
        conv['messages'] as List<dynamic>? ??
        [];

    final messages = <ImportedMessage>[];

    for (final msg in chatMessages) {
      if (msg is! Map<String, dynamic>) continue;

      // Claude uses 'sender' or 'role'
      final sender = msg['sender'] as String? ?? msg['role'] as String?;
      String? role;
      if (sender == 'human' || sender == 'user') {
        role = 'user';
      } else if (sender == 'assistant') {
        role = 'assistant';
      } else {
        continue; // Skip system messages, etc.
      }

      // Claude may have 'text' or 'content'
      String? content;
      final textField = msg['text'] ?? msg['content'];
      if (textField is String) {
        content = textField;
      } else if (textField is List) {
        // Content blocks format
        content = textField
            .whereType<Map<String, dynamic>>()
            .where((block) => block['type'] == 'text')
            .map((block) => block['text'] as String?)
            .whereType<String>()
            .join('\n');
      }

      if (content == null || content.trim().isEmpty) continue;

      final msgTimestamp = _parseIsoTimestamp(msg['created_at'] as String?) ??
          _parseIsoTimestamp(msg['createdAt'] as String?);

      messages.add(ImportedMessage(
        role: role,
        content: content.trim(),
        timestamp: msgTimestamp,
      ));
    }

    if (messages.isEmpty) return null;

    return ImportedConversation(
      originalId: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      source: ChatSource.claude,
    );
  }

  /// Import conversations and save them as Parachute session files
  ///
  /// Returns an ImportResult with details about the import.
  Future<ImportResult> importConversations(
    List<ImportedConversation> conversations, {
    bool archiveImports = true,
  }) async {
    final sessionsPath = await _fileSystem.getSessionsPath();
    await Directory(sessionsPath).create(recursive: true);

    // Get para ID service for generating message IDs
    final vaultPath = await _fileSystem.getRootPath();
    final paraIdService = ParaIdService(modulePath: vaultPath, module: 'chat');
    await paraIdService.initialize();

    final errors = <String>[];
    final sessions = <ChatSession>[];
    var importedCount = 0;
    var skippedCount = 0;

    for (final conv in conversations) {
      try {
        final session = await _saveConversation(
          conv,
          sessionsPath,
          paraIdService,
          archived: archiveImports,
        );
        sessions.add(session);
        importedCount++;
      } catch (e) {
        debugPrint('[ChatImport] Error saving conversation ${conv.title}: $e');
        errors.add('Failed to import "${conv.title}": $e');
        skippedCount++;
      }
    }

    debugPrint('[ChatImport] Import complete: $importedCount imported, $skippedCount skipped');

    return ImportResult(
      totalConversations: conversations.length,
      importedCount: importedCount,
      skippedCount: skippedCount,
      errors: errors,
      sessions: sessions,
    );
  }

  /// Save a single conversation as a Parachute session markdown file
  Future<ChatSession> _saveConversation(
    ImportedConversation conv,
    String sessionsPath,
    ParaIdService paraIdService, {
    required bool archived,
  }) async {
    // Generate new Parachute session ID
    final sessionId = _uuid.v4();

    // Build markdown content
    final buffer = StringBuffer();

    // YAML frontmatter
    buffer.writeln('---');
    buffer.writeln('sdk_session_id: $sessionId');
    buffer.writeln('title: "${_escapeYaml(conv.title)}"');
    buffer.writeln('created_at: ${conv.createdAt.toIso8601String()}');
    if (conv.updatedAt != null) {
      buffer.writeln('last_accessed: ${conv.updatedAt!.toIso8601String()}');
    }
    buffer.writeln('archived: $archived');
    buffer.writeln('source: ${conv.source.name}');
    buffer.writeln('original_id: ${conv.originalId}');
    buffer.writeln('---');
    buffer.writeln();

    // Messages
    for (final msg in conv.messages) {
      final roleLabel = msg.role == 'user' ? 'User' : 'Assistant';
      final paraId = await paraIdService.generate(type: ParaIdType.message);
      final timestamp = msg.timestamp?.toIso8601String() ??
          conv.createdAt.toIso8601String();

      buffer.writeln('### para:$paraId $roleLabel | $timestamp');
      buffer.writeln();
      buffer.writeln(msg.content);
      buffer.writeln();
    }

    // Write file
    final filename = _generateFilename(conv.title, conv.createdAt);
    final filePath = p.join(sessionsPath, filename);
    await File(filePath).writeAsString(buffer.toString());

    debugPrint('[ChatImport] Saved: $filePath');

    return ChatSession(
      id: sessionId,
      title: conv.title,
      createdAt: conv.createdAt,
      updatedAt: conv.updatedAt,
      messageCount: conv.messages.length,
      archived: archived,
      isLocal: true,
      source: conv.source,
      originalId: conv.originalId,
    );
  }

  /// Generate a safe filename for the session
  String _generateFilename(String title, DateTime createdAt) {
    final dateStr = createdAt.toIso8601String().split('T').first;
    final safeTitle = title
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase()
        .substring(0, title.length.clamp(0, 50));

    return '$dateStr-$safeTitle.md';
  }

  /// Escape special characters for YAML strings
  String _escapeYaml(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');
  }

  /// Parse Unix timestamp (seconds since epoch)
  DateTime? _parseUnixTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
    }
    return null;
  }

  /// Parse ISO 8601 timestamp string
  DateTime? _parseIsoTimestamp(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Detect the source type from file content
  ChatSource detectSource(String jsonContent) {
    try {
      final data = jsonDecode(jsonContent);

      if (data is List && data.isNotEmpty) {
        final first = data.first as Map<String, dynamic>?;
        if (first != null) {
          // ChatGPT has 'mapping' with message tree structure
          if (first.containsKey('mapping')) {
            return ChatSource.chatgpt;
          }
          // Claude has 'chat_messages' or uses 'sender' field
          if (first.containsKey('chat_messages') ||
              first.containsKey('sender')) {
            return ChatSource.claude;
          }
        }
      } else if (data is Map<String, dynamic>) {
        if (data.containsKey('mapping')) {
          return ChatSource.chatgpt;
        }
        if (data.containsKey('chat_messages') ||
            data.containsKey('conversations')) {
          return ChatSource.claude;
        }
      }
    } catch (_) {}

    return ChatSource.other;
  }
}
