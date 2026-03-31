/// Model for a chat log entry from AI conversations
class ChatLogEntry {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime? modifiedAt;
  final String? sessionId;

  ChatLogEntry({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    this.modifiedAt,
    this.sessionId,
  });

  /// Check if this entry has meaningful content
  bool get hasContent => content.trim().isNotEmpty;
}

/// Model for a day's chat log containing multiple entries
class ChatLog {
  final DateTime date;
  final List<ChatLogEntry> entries;

  ChatLog({
    required this.date,
    required this.entries,
  });

  /// Check if there are any entries
  bool get isEmpty => entries.isEmpty;

  /// Check if there are entries with content
  bool get hasContent => entries.any((e) => e.hasContent);
}
