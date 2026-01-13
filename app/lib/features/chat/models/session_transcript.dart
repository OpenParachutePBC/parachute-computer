import 'chat_message.dart';

/// Represents the full SDK transcript for a session
///
/// This contains the raw events from Claude SDK's JSONL storage,
/// which is much richer than the markdown summary.
///
/// Supports segmented loading for large transcripts:
/// - segments: Metadata about all segments (for UI to show collapsed headers)
/// - segmentCount: Total number of segments
/// - loadedSegmentIndex: Which segment is currently loaded (null if all/after_compact)
class SessionTranscript {
  final String sessionId;
  final String? transcriptPath;
  final int eventCount;
  final List<TranscriptEvent> events;

  /// Metadata about all transcript segments (for lazy loading UI)
  final List<TranscriptSegment> segments;

  /// Total number of segments in the transcript
  final int segmentCount;

  /// Which segment is currently loaded (null if all segments or after_compact mode)
  final int? loadedSegmentIndex;

  const SessionTranscript({
    required this.sessionId,
    this.transcriptPath,
    required this.eventCount,
    required this.events,
    this.segments = const [],
    this.segmentCount = 0,
    this.loadedSegmentIndex,
  });

  factory SessionTranscript.fromJson(Map<String, dynamic> json) {
    final eventsList = json['events'] as List<dynamic>? ?? [];
    final segmentsList = json['segments'] as List<dynamic>? ?? [];

    return SessionTranscript(
      sessionId: json['sessionId'] as String? ?? '',
      transcriptPath: json['transcriptPath'] as String?,
      eventCount: json['eventCount'] as int? ?? eventsList.length,
      events: eventsList
          .map((e) => TranscriptEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      segments: segmentsList
          .map((s) => TranscriptSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      segmentCount: json['segmentCount'] as int? ?? 0,
      loadedSegmentIndex: json['loadedSegmentIndex'] as int?,
    );
  }

  /// Whether there are earlier segments that can be loaded
  bool get hasEarlierSegments =>
      segmentCount > 1 && (loadedSegmentIndex == null || loadedSegmentIndex! > 0);

  /// Convert transcript events into ChatMessage objects
  ///
  /// The SDK transcript structure:
  /// - `user` events with `text` content = human messages (turn boundaries)
  /// - `user` events with `tool_result` content = tool responses (NOT human messages)
  /// - `assistant` events = AI responses (text, tool_use, thinking)
  /// - `system` events with `subtype: compact_boundary` = compaction markers
  ///
  /// Each assistant event represents a SEPARATE API call, not streaming updates.
  /// We aggregate ALL assistant content between human messages into one ChatMessage.
  ///
  /// Messages marked with `isCompactSummary: true` are auto-generated summaries
  /// that should be displayed collapsed in the UI.
  List<ChatMessage> toMessages() {
    final messages = <ChatMessage>[];

    // Track accumulated assistant content between human messages
    List<MessageContent> pendingAssistantContent = [];
    DateTime? assistantTimestamp;
    String? assistantId;
    bool pendingIsCompactSummary = false;

    for (final event in events) {
      // Skip compact boundary markers (they're just metadata)
      if (event.isCompactBoundary) {
        continue;
      }

      if (event.type == 'user' && event.message != null) {
        final content = event.message!['content'];

        // Check if this is a human message (text) or tool result
        bool isHumanMessage = false;
        String humanText = '';
        bool userIsCompactSummary = event.isCompactSummary;

        if (content is String) {
          isHumanMessage = true;
          humanText = content;
        } else if (content is List) {
          for (final block in content) {
            if (block is Map) {
              if (block['type'] == 'text') {
                isHumanMessage = true;
                humanText += block['text'] as String? ?? '';
                // Check block-level compact summary flag
                if (block['isCompactSummary'] == true) {
                  userIsCompactSummary = true;
                }
              }
              // tool_result blocks are NOT human messages
            }
          }
        }

        if (isHumanMessage && humanText.isNotEmpty) {
          // First, flush any pending assistant content
          if (pendingAssistantContent.isNotEmpty) {
            messages.add(ChatMessage(
              id: assistantId ?? DateTime.now().millisecondsSinceEpoch.toString(),
              sessionId: sessionId,
              role: MessageRole.assistant,
              content: pendingAssistantContent,
              timestamp: assistantTimestamp ?? DateTime.now(),
              isCompactSummary: pendingIsCompactSummary,
            ));
            pendingAssistantContent = [];
            assistantTimestamp = null;
            assistantId = null;
            pendingIsCompactSummary = false;
          }

          // Add the human message
          messages.add(ChatMessage(
            id: event.uuid ?? DateTime.now().millisecondsSinceEpoch.toString(),
            sessionId: sessionId,
            role: MessageRole.user,
            content: [MessageContent.text(humanText)],
            timestamp: event.timestamp ?? DateTime.now(),
            isCompactSummary: userIsCompactSummary,
          ));
        }
        // If it's a tool_result, we just skip it (don't show in UI)

      } else if (event.type == 'assistant' && event.message != null) {
        final content = event.message!['content'];

        // Set timestamp from first assistant event in this group
        assistantTimestamp ??= event.timestamp;
        assistantId ??= event.uuid;

        // Track if any event in this group is a compact summary
        if (event.isCompactSummary) {
          pendingIsCompactSummary = true;
        }

        if (content is List) {
          for (final block in content) {
            if (block is! Map) continue;
            final blockType = block['type'] as String?;

            // Check block-level compact summary flag
            if (block['isCompactSummary'] == true) {
              pendingIsCompactSummary = true;
            }

            if (blockType == 'text') {
              final text = block['text'] as String? ?? '';
              if (text.isNotEmpty) {
                pendingAssistantContent.add(MessageContent.text(text));
              }
            } else if (blockType == 'tool_use') {
              // When we see a tool_use, convert any preceding text to thinking
              // (text before tools is "thinking out loud", not final response)
              for (int i = 0; i < pendingAssistantContent.length; i++) {
                if (pendingAssistantContent[i].type == ContentType.text) {
                  final thinkingText = pendingAssistantContent[i].text ?? '';
                  if (thinkingText.isNotEmpty) {
                    pendingAssistantContent[i] = MessageContent.thinking(thinkingText);
                  }
                }
              }
              pendingAssistantContent.add(MessageContent.toolUse(ToolCall(
                id: block['id'] as String? ?? '',
                name: block['name'] as String? ?? '',
                input: block['input'] as Map<String, dynamic>? ?? {},
              )));
            } else if (blockType == 'thinking') {
              final thinking = block['thinking'] as String? ?? '';
              if (thinking.isNotEmpty) {
                pendingAssistantContent.add(MessageContent.thinking(thinking));
              }
            }
          }
        }
      }
    }

    // Flush any remaining assistant content
    if (pendingAssistantContent.isNotEmpty) {
      messages.add(ChatMessage(
        id: assistantId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        sessionId: sessionId,
        role: MessageRole.assistant,
        content: pendingAssistantContent,
        timestamp: assistantTimestamp ?? DateTime.now(),
        isCompactSummary: pendingIsCompactSummary,
      ));
    }

    return messages;
  }
}

/// A single event from the SDK transcript
class TranscriptEvent {
  final String type;
  final String? subtype;
  final String? uuid;
  final String? parentUuid;
  final DateTime? timestamp;
  final Map<String, dynamic>? message;
  final Map<String, dynamic> raw;

  /// Whether this event is a compact summary (auto-generated by Claude SDK)
  final bool isCompactSummary;

  const TranscriptEvent({
    required this.type,
    this.subtype,
    this.uuid,
    this.parentUuid,
    this.timestamp,
    this.message,
    required this.raw,
    this.isCompactSummary = false,
  });

  factory TranscriptEvent.fromJson(Map<String, dynamic> json) {
    DateTime? timestamp;
    final tsValue = json['timestamp'];
    if (tsValue is String) {
      timestamp = DateTime.tryParse(tsValue);
    } else if (tsValue is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(tsValue);
    }

    // Detect compact summary messages:
    // - Message with isCompactSummary: true
    // - Message content blocks with isCompactSummary: true
    bool isCompactSummary = json['isCompactSummary'] as bool? ?? false;

    // Also check message-level flag
    final message = json['message'] as Map<String, dynamic>?;
    if (message != null && message['isCompactSummary'] == true) {
      isCompactSummary = true;
    }

    return TranscriptEvent(
      type: json['type'] as String? ?? 'unknown',
      subtype: json['subtype'] as String?,
      uuid: json['uuid'] as String?,
      parentUuid: json['parentUuid'] as String?,
      timestamp: timestamp,
      message: message,
      raw: json,
      isCompactSummary: isCompactSummary,
    );
  }

  /// Check if this is a compact boundary marker
  bool get isCompactBoundary => type == 'system' && subtype == 'compact_boundary';
}

/// Metadata about a transcript segment (for lazy loading UI)
///
/// Segments are divided by compact boundaries. The last segment contains
/// the most recent messages (after the last compaction).
class TranscriptSegment {
  /// Index of this segment (0 = oldest, last = most recent)
  final int index;

  /// Whether this segment contains compacted/summarized content
  final bool isCompacted;

  /// Number of messages in this segment
  final int messageCount;

  /// Number of raw events in this segment
  final int eventCount;

  /// Start time of this segment
  final DateTime? startTime;

  /// End time of this segment
  final DateTime? endTime;

  /// Preview text for collapsed display
  final String? preview;

  /// Whether this segment's events are currently loaded
  final bool loaded;

  const TranscriptSegment({
    required this.index,
    required this.isCompacted,
    required this.messageCount,
    required this.eventCount,
    this.startTime,
    this.endTime,
    this.preview,
    this.loaded = false,
  });

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      index: json['index'] as int? ?? 0,
      isCompacted: json['isCompacted'] as bool? ?? false,
      messageCount: json['messageCount'] as int? ?? 0,
      eventCount: json['eventCount'] as int? ?? 0,
      startTime: json['startTime'] != null
          ? DateTime.tryParse(json['startTime'] as String)
          : null,
      endTime: json['endTime'] != null
          ? DateTime.tryParse(json['endTime'] as String)
          : null,
      preview: json['preview'] as String?,
      loaded: json['loaded'] as bool? ?? false,
    );
  }

  /// Format the time range for display
  String get timeRangeDisplay {
    if (startTime == null && endTime == null) return '';
    if (startTime != null && endTime != null) {
      return '${_formatDate(startTime!)} - ${_formatDate(endTime!)}';
    }
    return startTime != null ? _formatDate(startTime!) : _formatDate(endTime!);
  }

  String _formatDate(DateTime dt) {
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}
