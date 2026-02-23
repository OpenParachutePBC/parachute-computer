/// Typed model for a pending AskUserQuestion request.
///
/// Replaces the untyped [Map<String, dynamic>] that was previously
/// stored in [ChatMessagesState.pendingUserQuestion].
class PendingUserQuestion {
  final String requestId;
  final String sessionId;
  final List<Map<String, dynamic>> questions;

  const PendingUserQuestion({
    required this.requestId,
    required this.sessionId,
    required this.questions,
  });
}
