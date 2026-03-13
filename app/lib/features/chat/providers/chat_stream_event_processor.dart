import '../models/chat_message.dart';
import '../models/prompt_metadata.dart';
import '../models/stream_event.dart';

/// State patch produced by the processor for events that update notifier state.
///
/// The notifier applies these patches to its state after processing each event.
/// Only non-null fields should be applied.
class ChatStatePatch {
  final String? model;
  final PromptMetadata? promptMetadata;

  const ChatStatePatch({this.model, this.promptMetadata});
}

/// Processes SSE stream events and produces content updates.
///
/// Extracts the common event-handling logic shared between the
/// sendMessage and reattach-to-background-stream paths. Both paths
/// handle text, toolUse, toolResult, thinking, and warning identically —
/// the only difference is how content updates are routed to the UI
/// (abstracted via the [onUpdate] and [onFlush] callbacks).
///
/// Terminal events (done, error, session, sessionUnavailable, userMessage,
/// userQuestion, aborted) are NOT handled here because they have
/// fundamentally different behavior between the send and reattach paths.
class ChatStreamEventProcessor {
  /// Accumulated content blocks for the current assistant message.
  final List<MessageContent> content = [];

  /// Callback to update the assistant message in the UI.
  /// [immediate] = true bypasses throttling (used for tool events).
  final void Function(
    List<MessageContent> content, {
    required bool isStreaming,
    bool immediate,
  }) onUpdate;

  /// Callback to flush any throttled pending updates.
  final void Function() onFlush;

  /// Callback to build PromptMetadata from a stream event.
  final PromptMetadata Function(StreamEvent event) buildPromptMetadata;

  ChatStreamEventProcessor({
    required this.onUpdate,
    required this.onFlush,
    required this.buildPromptMetadata,
  });

  /// Process a single stream event.
  ///
  /// Returns a [ChatStatePatch] if the event updates notifier-level state
  /// (model, promptMetadata), or null if only content was updated.
  ///
  /// Returns null without side effects for unhandled event types —
  /// the caller should handle those (terminal events, path-specific events).
  ChatStatePatch? processEvent(StreamEvent event) {
    switch (event.type) {
      case StreamEventType.model:
        return _handleModel(event);
      case StreamEventType.promptMetadata:
        return _handlePromptMetadata(event);
      case StreamEventType.text:
        _handleText(event);
        return null;
      case StreamEventType.toolUse:
        _handleToolUse(event);
        return null;
      case StreamEventType.toolResult:
        _handleToolResult(event);
        return null;
      case StreamEventType.thinking:
        _handleThinking(event);
        return null;
      case StreamEventType.warning:
        _handleWarning(event);
        return null;
      default:
        // Terminal and path-specific events are not handled here.
        return null;
    }
  }

  /// Whether this event type is handled by the processor.
  ///
  /// Callers can use this to skip their own switch/case for handled events.
  bool handles(StreamEventType type) {
    switch (type) {
      case StreamEventType.model:
      case StreamEventType.promptMetadata:
      case StreamEventType.text:
      case StreamEventType.toolUse:
      case StreamEventType.toolResult:
      case StreamEventType.thinking:
      case StreamEventType.warning:
        return true;
      default:
        return false;
    }
  }

  /// Reset accumulated content. Call on stream end (done/error/aborted).
  void reset() => content.clear();

  // -- Event handlers --

  ChatStatePatch _handleModel(StreamEvent event) {
    final model = event.model;
    return ChatStatePatch(model: model);
  }

  ChatStatePatch _handlePromptMetadata(StreamEvent event) {
    final metadata = buildPromptMetadata(event);
    return ChatStatePatch(promptMetadata: metadata);
  }

  void _handleText(StreamEvent event) {
    final text = event.textContent;
    if (text == null) return;

    // Replace the last text block (server sends accumulated text) or add new
    final lastTextIndex = content.lastIndexWhere(
      (c) => c.type == ContentType.text,
    );
    if (lastTextIndex >= 0) {
      content[lastTextIndex] = MessageContent.text(text);
    } else {
      content.add(MessageContent.text(text));
    }
    onUpdate(content, isStreaming: true);
  }

  void _handleToolUse(StreamEvent event) {
    // Flush any pending throttled updates before showing tool call
    onFlush();

    final toolCall = event.toolCall;
    if (toolCall == null) return;

    // Convert any pending text to "thinking" before the tool call
    final lastTextIndex = content.lastIndexWhere(
      (c) => c.type == ContentType.text,
    );
    if (lastTextIndex >= 0) {
      final thinkingText = content[lastTextIndex].text ?? '';
      if (thinkingText.isNotEmpty) {
        content[lastTextIndex] = MessageContent.thinking(thinkingText);
      }
    }
    content.add(MessageContent.toolUse(toolCall));
    // Force immediate update (not throttled)
    onUpdate(content, isStreaming: true, immediate: true);
  }

  void _handleToolResult(StreamEvent event) {
    final toolUseId = event.toolUseId;
    final resultContent = event.toolResultContent;
    if (toolUseId == null || resultContent == null) return;

    // Find the tool call with this ID and attach the result
    for (int i = 0; i < content.length; i++) {
      final item = content[i];
      if (item.type == ContentType.toolUse && item.toolCall?.id == toolUseId) {
        final updatedToolCall = item.toolCall!.withResult(
          resultContent,
          isError: event.toolResultIsError,
        );
        content[i] = MessageContent.toolUse(updatedToolCall);
        onUpdate(content, isStreaming: true);
        break;
      }
    }
  }

  void _handleThinking(StreamEvent event) {
    final thinkingText = event.thinkingContent;
    if (thinkingText == null || thinkingText.isEmpty) return;

    content.add(MessageContent.thinking(thinkingText));
    onUpdate(content, isStreaming: true);
  }

  void _handleWarning(StreamEvent event) {
    final title = (event.data['title'] as String?) ?? 'Warning';
    final msg = (event.data['message'] as String?) ?? '';
    final details = (event.data['details'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        [];
    final warningText = details.isNotEmpty
        ? '$title: $msg\n${details.map((d) => '  - $d').join('\n')}'
        : '$title: $msg';

    content.add(MessageContent.warning(warningText));
    onUpdate(content, isStreaming: true);
  }
}
