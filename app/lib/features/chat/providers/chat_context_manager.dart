import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';

/// Manages context file persistence and prior-message formatting for chat sessions.
///
/// Extracts I/O and formatting logic from [ChatMessagesNotifier] so the notifier
/// focuses on state orchestration rather than business logic details.
class ChatContextManager {
  final ChatService _service;

  ChatContextManager(this._service);

  /// Persist context selection to database for a session.
  ///
  /// No-op if [sessionId] is null or "pending" (contexts will be persisted
  /// when the real session ID arrives in the done event).
  Future<void> persistContexts(String? sessionId, List<String> contexts) async {
    if (sessionId == null || sessionId == 'pending') {
      debugPrint('[ChatContextManager] No session ID yet, contexts will be persisted after first message');
      return;
    }

    try {
      await _service.setSessionContextFolders(sessionId, contexts);
      debugPrint('[ChatContextManager] Persisted contexts to database: $contexts');
    } catch (e) {
      debugPrint('[ChatContextManager] Failed to persist contexts: $e');
      // Don't rethrow — local state is still updated, persistence is best-effort
    }
  }

  /// Format prior messages as context for the AI.
  ///
  /// Returns the most recent messages that fit within ~50k chars, formatted as
  /// "Human: ..." / "Assistant: ..." pairs. The server wraps this in its own
  /// header, so we provide raw content only.
  ///
  /// Returns empty string if [priorMessages] is empty.
  String formatPriorMessagesAsContext(List<ChatMessage> priorMessages) {
    if (priorMessages.isEmpty) return '';

    const maxChars = 50000;
    final buffer = StringBuffer();

    // Take most recent messages that fit within limit
    final messages = priorMessages.reversed.toList();
    final selectedMessages = <ChatMessage>[];
    int totalChars = 0;

    for (final msg in messages) {
      final content = msg.textContent;
      if (content.isEmpty) continue;

      final msgText = '${msg.role == MessageRole.user ? "Human" : "Assistant"}: $content\n\n';
      if (totalChars + msgText.length > maxChars) break;

      totalChars += msgText.length;
      selectedMessages.insert(0, msg);
    }

    for (final msg in selectedMessages) {
      final role = msg.role == MessageRole.user ? 'Human' : 'Assistant';
      final content = msg.textContent;
      buffer.writeln('$role: $content\n');
    }

    debugPrint('[ChatContextManager] Formatted ${selectedMessages.length}/${priorMessages.length} prior messages ($totalChars chars)');
    return buffer.toString().trim();
  }

  /// Toggle a context path on or off in a list. Returns the updated list.
  List<String> toggleContext(String contextPath, List<String> current) {
    final updated = List<String>.from(current);
    if (updated.contains(contextPath)) {
      updated.remove(contextPath);
    } else {
      updated.add(contextPath);
    }
    return updated;
  }
}
