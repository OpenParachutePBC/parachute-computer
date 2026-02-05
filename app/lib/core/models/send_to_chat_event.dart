/// Event model for sending content from other features to Chat
class SendToChatEvent {
  final String content;
  final String? title;
  final String? sessionId; // null = new chat
  final String? agentType; // for new chats only
  final String? agentPath; // path to agent definition file

  const SendToChatEvent({
    required this.content,
    this.title,
    this.sessionId,
    this.agentType,
    this.agentPath,
  });

  /// Format message with title if available
  String get formattedMessage {
    return title != null && title!.isNotEmpty
        ? '**$title**\n\n$content'
        : content;
  }
}
