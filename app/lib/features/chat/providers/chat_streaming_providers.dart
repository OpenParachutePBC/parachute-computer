import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================
// Streaming State
// ============================================================

/// Pending chat prompt to pre-fill when navigating to chat
///
/// Set this before switching to the chat tab to have the message
/// pre-filled in the input field. The chat screen will read and
/// clear this when it becomes active.
class PendingChatPrompt {
  final String message;
  final String? sessionId; // null = new chat
  final String? agentType; // for new chats only
  final String? agentPath; // path to agent definition file

  const PendingChatPrompt({
    required this.message,
    this.sessionId,
    this.agentType,
    this.agentPath,
  });
}

final pendingChatPromptProvider = StateProvider<PendingChatPrompt?>((ref) => null);
