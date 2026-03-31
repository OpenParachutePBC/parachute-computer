import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:parachute/core/services/file_system_service.dart';
import '../models/chat_log.dart';

/// Service for reading chat log files from the vault
class ChatLogService {
  final String _rootPath;
  // ignore: unused_field
  final FileSystemService _fileSystemService;

  ChatLogService._({
    required String rootPath,
    required FileSystemService fileSystemService,
  })  : _rootPath = rootPath,
        _fileSystemService = fileSystemService;

  /// Create a ChatLogService instance
  static Future<ChatLogService> create({
    required FileSystemService fileSystemService,
  }) async {
    // Use the configured chat log path from FileSystemService
    final chatLogPath = await fileSystemService.getChatLogPath();
    return ChatLogService._(
      rootPath: chatLogPath,
      fileSystemService: fileSystemService,
    );
  }

  /// Path to chat-log directory (configured via settings)
  String get chatLogPath => _rootPath;

  /// Load chat log for a specific date
  Future<ChatLog?> loadChatLog(DateTime date) async {
    final dateStr = _formatDate(date);
    final filePath = '$chatLogPath/$dateStr.md';

    debugPrint('[ChatLogService] Loading chat log from: $filePath');

    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('[ChatLogService] No chat log file found for $dateStr');
      return null;
    }

    try {
      final content = await file.readAsString();
      return _parseChatLog(date, content);
    } catch (e) {
      debugPrint('[ChatLogService] Error loading chat log: $e');
      return null;
    }
  }

  /// Parse a chat log markdown file into a ChatLog model
  ChatLog _parseChatLog(DateTime date, String content) {
    final entries = <ChatLogEntry>[];

    // Split by para: headers
    final paraPattern = RegExp(r'^# para:(\w+)\s+(\d{2}:\d{2})\s*$', multiLine: true);
    final matches = paraPattern.allMatches(content).toList();

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final id = match.group(1)!;
      final timeStr = match.group(2)!;

      // Get content between this header and the next (or end of file)
      final startIndex = match.end;
      final endIndex = i < matches.length - 1 ? matches[i + 1].start : content.length;
      var sectionContent = content.substring(startIndex, endIndex).trim();

      // Extract title (first line that starts with **)
      String title = 'Chat Session';
      final titleMatch = RegExp(r'^\*\*(.+?)\*\*', multiLine: true).firstMatch(sectionContent);
      if (titleMatch != null) {
        title = titleMatch.group(1)!;
      }

      // Extract session ID if present
      String? sessionId;
      final sessionMatch = RegExp(r'Session:\s*`([a-f0-9-]+)`').firstMatch(sectionContent);
      if (sessionMatch != null) {
        sessionId = sessionMatch.group(1);
      }
      // Also check for parachute:// link
      final linkMatch = RegExp(r'parachute://chat/session/([a-f0-9-]+)').firstMatch(sectionContent);
      if (linkMatch != null) {
        sessionId = linkMatch.group(1);
      }

      // Parse time
      final timeParts = timeStr.split(':');
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);
      final createdAt = DateTime(date.year, date.month, date.day, hour, minute);

      // Remove the title line from content for cleaner display
      if (titleMatch != null) {
        sectionContent = sectionContent.substring(titleMatch.end).trim();
      }
      // Remove session link line
      sectionContent = sectionContent.replaceFirst(RegExp(r'\[Open session\]\([^)]+\)\s*'), '').trim();
      // Remove Session: line
      sectionContent = sectionContent.replaceFirst(RegExp(r'Session:\s*`[^`]+`\s*'), '').trim();
      // Remove leading/trailing ---
      sectionContent = sectionContent.replaceAll(RegExp(r'^---\s*'), '').replaceAll(RegExp(r'\s*---$'), '').trim();

      entries.add(ChatLogEntry(
        id: id,
        title: title,
        content: sectionContent,
        createdAt: createdAt,
        sessionId: sessionId,
      ));
    }

    debugPrint('[ChatLogService] Parsed ${entries.length} chat log entries');
    return ChatLog(date: date, entries: entries);
  }

  /// List dates that have chat log files
  Future<List<DateTime>> listChatLogDates() async {
    final dir = Directory(chatLogPath);
    if (!await dir.exists()) {
      debugPrint('[ChatLogService] Chat log directory does not exist: $chatLogPath');
      return [];
    }

    final dates = <DateTime>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.md')) {
        final fileName = entity.path.split('/').last;
        final dateStr = fileName.replaceAll('.md', '');
        final date = _parseDate(dateStr);
        if (date != null) {
          dates.add(date);
        }
      }
    }

    dates.sort((a, b) => b.compareTo(a)); // Most recent first
    debugPrint('[ChatLogService] Found ${dates.length} chat log dates');
    return dates;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  DateTime? _parseDate(String dateStr) {
    try {
      final parts = dateStr.split('-');
      if (parts.length != 3) return null;
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (e) {
      return null;
    }
  }
}
