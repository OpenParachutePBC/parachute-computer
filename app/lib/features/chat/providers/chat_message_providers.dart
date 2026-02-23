import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import '../models/stream_event.dart';
import '../models/session_resume_info.dart';
import '../models/prompt_metadata.dart';
import '../models/session_transcript.dart';
import '../models/attachment.dart';
import '../services/chat_service.dart';
import '../services/background_stream_manager.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/providers/core_service_providers.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show modelPreferenceProvider;
import 'chat_session_actions.dart' show newChatModeProvider;
import 'chat_session_providers.dart';
import 'workspace_providers.dart' show activeWorkspaceProvider;

// ============================================================
// Performance Tracing (inline stub)
// ============================================================

/// Simple performance trace for measuring operation duration
class _PerformanceTrace {
  final Stopwatch _stopwatch = Stopwatch()..start();

  void end({Map<String, dynamic>? additionalData}) {
    _stopwatch.stop();
    // Stub: just stops the timer, no logging
  }
}

class _PerfStub {
  _PerformanceTrace trace(String name, {Map<String, dynamic>? metadata}) {
    return _PerformanceTrace();
  }
}

final _perf = _PerfStub();

// ============================================================
// Chat State Management
// ============================================================

/// State for the chat messages list with streaming support
class ChatMessagesState {
  final List<ChatMessage> messages;
  final bool isStreaming;
  final String? error;
  final String? sessionId;
  final String? sessionTitle;

  /// Working directory for this session (relative to vault)
  /// If set, the agent operates in this directory and loads its CLAUDE.md
  /// Default is null, which means the vault root (~/Parachute)
  final String? workingDirectory;

  /// If this is a continuation, the original session being continued
  final ChatSession? continuedFromSession;

  /// Messages from the original session (for display in resume marker)
  final List<ChatMessage> priorMessages;

  /// The session being viewed (for archived sessions that need to be resumed)
  /// Set when loading an archived session - shows "Resume" prompt
  final ChatSession? viewingSession;

  /// Information about how the session was resumed
  /// Set when receiving a session or done event from the backend
  final SessionResumeInfo? sessionResumeInfo;

  /// Session unavailability info - set when SDK session cannot be resumed
  /// Contains info for showing recovery dialog to user
  final SessionUnavailableInfo? sessionUnavailable;

  /// Whether the session is currently loading (e.g., during session switch)
  final bool isLoading;

  /// The model being used for this session (e.g., 'claude-opus-4-5-20250514')
  /// Set when receiving model event from backend
  final String? model;

  /// Metadata about the system prompt composition (for transparency)
  /// Set when receiving prompt_metadata event from backend
  final PromptMetadata? promptMetadata;

  /// Transcript segments for lazy loading (metadata only for unloaded segments)
  final List<TranscriptSegment> transcriptSegments;

  /// Total number of transcript segments
  final int transcriptSegmentCount;

  /// Selected context files for this session
  /// These are passed to the server with each message
  /// Paths are relative to vault (e.g., "Chat/contexts/general-context.md")
  final List<String> selectedContexts;

  /// Whether the user has explicitly set context preferences
  /// When false, server uses defaults. When true, we send selectedContexts (even if empty).
  final bool contextsExplicitlySet;

  /// Whether to reload the working directory CLAUDE.md on next message
  /// Set to true when user wants to refresh project context
  final bool reloadClaudeMd;

  /// Pending user question from AskUserQuestion tool
  /// When set, UI should display a question card for user to answer
  /// Map contains: requestId, sessionId, questions
  final Map<String, dynamic>? pendingUserQuestion;

  /// Trust level for this session (direct, sandboxed)
  /// Set from SSE session event so config sheet can display it immediately
  final String? trustLevel;

  const ChatMessagesState({
    this.messages = const [],
    this.isStreaming = false,
    this.isLoading = false,
    this.error,
    this.sessionId,
    this.sessionTitle,
    this.workingDirectory,
    this.continuedFromSession,
    this.priorMessages = const [],
    this.viewingSession,
    this.sessionResumeInfo,
    this.sessionUnavailable,
    this.model,
    this.promptMetadata,
    this.transcriptSegments = const [],
    this.transcriptSegmentCount = 0,
    this.selectedContexts = const [],
    this.contextsExplicitlySet = false,
    this.reloadClaudeMd = false,
    this.pendingUserQuestion,
    this.trustLevel,
  });

  /// Whether this session is continuing from another
  bool get isContinuation => continuedFromSession != null;

  /// Whether we're viewing an archived session that needs to be resumed
  /// Archived sessions show a "Resume" prompt and disabled input until resumed
  bool get isViewingArchived => viewingSession?.archived ?? false;

  /// Whether there are earlier segments that haven't been loaded yet
  bool get hasEarlierSegments => transcriptSegmentCount > 1 &&
      transcriptSegments.any((s) => !s.loaded && s.index < transcriptSegmentCount - 1);

  ChatMessagesState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    bool? isLoading,
    String? error,
    String? sessionId,
    String? sessionTitle,
    String? workingDirectory,
    ChatSession? continuedFromSession,
    List<ChatMessage>? priorMessages,
    ChatSession? viewingSession,
    ChatSession? currentSession,
    SessionResumeInfo? sessionResumeInfo,
    SessionUnavailableInfo? sessionUnavailable,
    String? model,
    PromptMetadata? promptMetadata,
    List<TranscriptSegment>? transcriptSegments,
    int? transcriptSegmentCount,
    List<String>? selectedContexts,
    bool? contextsExplicitlySet,
    bool? reloadClaudeMd,
    Map<String, dynamic>? pendingUserQuestion,
    String? trustLevel,
    bool clearSessionUnavailable = false,
    bool clearWorkingDirectory = false,
    bool clearViewingSession = false,
    bool clearPendingUserQuestion = false,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      sessionId: sessionId ?? currentSession?.id ?? this.sessionId,
      sessionTitle: sessionTitle ?? currentSession?.title ?? this.sessionTitle,
      workingDirectory: clearWorkingDirectory ? null : (workingDirectory ?? currentSession?.workingDirectory ?? this.workingDirectory),
      continuedFromSession: continuedFromSession ?? this.continuedFromSession,
      priorMessages: priorMessages ?? this.priorMessages,
      viewingSession: clearViewingSession ? null : (viewingSession ?? this.viewingSession),
      model: model ?? this.model,
      promptMetadata: promptMetadata ?? this.promptMetadata,
      sessionResumeInfo: sessionResumeInfo ?? this.sessionResumeInfo,
      sessionUnavailable: clearSessionUnavailable ? null : (sessionUnavailable ?? this.sessionUnavailable),
      transcriptSegments: transcriptSegments ?? this.transcriptSegments,
      transcriptSegmentCount: transcriptSegmentCount ?? this.transcriptSegmentCount,
      selectedContexts: selectedContexts ?? this.selectedContexts,
      contextsExplicitlySet: contextsExplicitlySet ?? this.contextsExplicitlySet,
      reloadClaudeMd: reloadClaudeMd ?? this.reloadClaudeMd,
      pendingUserQuestion: clearPendingUserQuestion ? null : (pendingUserQuestion ?? this.pendingUserQuestion),
      trustLevel: trustLevel ?? this.trustLevel,
    );
  }
}

class SessionUnavailableInfo {
  final String sessionId;
  final String reason;
  final bool hasMarkdownHistory;
  final int messageCount;
  final String message;

  /// The original message that was being sent when the error occurred
  final String pendingMessage;

  const SessionUnavailableInfo({
    required this.sessionId,
    required this.reason,
    required this.hasMarkdownHistory,
    required this.messageCount,
    required this.message,
    required this.pendingMessage,
  });
}

/// Mutable context for a single sendMessage() stream.
///
/// Holds the state that was previously captured in sendMessage() local
/// variables.  Shared between the registration site and the event callback
/// via closure.
class _SendStreamContext {
  List<MessageContent> accumulatedContent = [];
  String? actualSessionId;
  String displaySessionId;
  final String originalMessage;

  _SendStreamContext({
    required this.displaySessionId,
    required this.originalMessage,
  });
}

/// Notifier for managing chat messages and streaming
class ChatMessagesNotifier extends StateNotifier<ChatMessagesState> {
  final ChatService _service;
  final Ref _ref;
  final _log = logger.createLogger('ChatMessagesNotifier');

  /// Track the session ID of the currently active stream
  /// Used to prevent old streams from updating state after session switch
  String? _activeStreamSessionId;

  /// Throttle for UI updates during streaming (50ms = ~20 updates/sec max)
  final _streamingThrottle = Throttle(const Duration(milliseconds: 50));

  /// Track pending content updates for batching.
  /// When non-null, [_pendingSessionId] distinguishes the reattach path
  /// (non-null session ID → flush via [_updateOrAddAssistantMessage]) from the
  /// sendMessage path (null → flush via [_performMessageUpdate]).
  List<MessageContent>? _pendingContent;
  String? _pendingSessionId;

  /// Background stream manager for handling streams that survive navigation
  final BackgroundStreamManager _streamManager;

  /// Current stream subscription (for cleanup when navigating away)
  StreamSubscription<StreamEvent>? _currentStreamSubscription;

  /// Message that failed mid-stream inject and needs to be re-sent as a new turn
  String? _pendingResendMessage;

  /// Messages queued while streaming is active.
  ///
  /// When the user sends a message mid-stream, we defer showing it in the UI
  /// until the current stream completes. This prevents the jarring visual
  /// where the new user message appears above a still-streaming assistant
  /// response. Messages are flushed (via sendMessage) on the done event.
  final List<String> _queuedMessages = [];

  /// Prevents overlapping async poll callbacks when HTTP takes >2s
  bool _isPolling = false;

  /// Active send-stream context (null when no sendMessage stream is running)
  _SendStreamContext? _sendStreamCtx;

  ChatMessagesNotifier(this._service, this._streamManager, this._ref) : super(const ChatMessagesState());

  /// Format warning event data into display text
  String _formatWarningText(StreamEvent event) {
    final title = (event.data['title'] as String?) ?? 'Warning';
    final msg = (event.data['message'] as String?) ?? '';
    final details = (event.data['details'] as List<dynamic>?)?.whereType<String>().toList() ?? [];
    return details.isNotEmpty
        ? '$title: $msg\n${details.map((d) => '  - $d').join('\n')}'
        : '$title: $msg';
  }

  /// Reset all mutable transient state that should not persist across sessions.
  /// Called from prepareForSessionSwitch, clearSession, and dispose.
  ///
  /// NOTE: This cancels the UI *subscription* to the broadcast controller,
  /// but does NOT cancel the background stream itself.  The
  /// BackgroundStreamManager continues consuming the HTTP stream so the
  /// server finishes processing.
  void _resetTransientState() {
    _currentStreamSubscription?.cancel();
    _currentStreamSubscription = null;
    _activeStreamSessionId = null;
    _sendStreamCtx = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _isPolling = false;
    _streamingThrottle.reset();
    _reattachStreamContent.clear();
    _pendingContent = null;
    _pendingSessionId = null;
    _pendingResendMessage = null;
    _queuedMessages.clear();
  }

  /// Enable input for an archived session so the user can resume it
  ///
  /// This clears the "viewing archived" state while keeping the session loaded,
  /// allowing the user to send messages to continue the conversation.
  /// Also unarchives the session on the server.
  void enableSessionInput(ChatSession session) {
    // Clear viewingSession to enable input, but keep everything else
    state = state.copyWith(
      clearViewingSession: true,  // This enables input (isViewingArchived becomes false)
      currentSession: session,  // Keep the session for sending messages
    );
    // Update the current session ID provider so messages go to this session
    _ref.read(currentSessionIdProvider.notifier).state = session.id;
  }

  /// Prepare state for switching to a new session
  ///
  /// Clears old messages immediately and shows loading state to prevent
  /// stale content from being displayed during async session load.
  void prepareForSessionSwitch(String newSessionId) {
    _resetTransientState();

    // Check if the new session has an active background stream
    final hasActiveStream = _streamManager.hasActiveStream(newSessionId);

    // Clear messages immediately and show loading state
    state = ChatMessagesState(
      sessionId: newSessionId,
      isLoading: true,
      isStreaming: hasActiveStream,
    );
  }

  /// Load messages for a session
  ///
  /// First tries to load the rich SDK transcript (with tool calls, thinking, etc.),
  /// then falls back to markdown messages from the API.
  /// Also cancels any active stream by invalidating the stream session ID.
  /// If the session was continued from another session, loads prior messages too.
  /// If there's an active background stream for this session, reattaches to it.
  Future<void> loadSession(String sessionId) async {
    final trace = _perf.trace('LoadSession', metadata: {'sessionId': sessionId});

    // Cancel subscription to current stream (but let it continue in background)
    _currentStreamSubscription?.cancel();
    _currentStreamSubscription = null;
    _activeStreamSessionId = null;

    // Check if there's an active background stream for this session (in-memory)
    bool hasActiveStream = _streamManager.hasActiveStream(sessionId);
    if (hasActiveStream) {
      debugPrint('[ChatMessagesNotifier] Reattaching to active background stream for: $sessionId');
      _activeStreamSessionId = sessionId;
    }

    try {
      ChatSession? loadedSession;
      ChatSessionWithMessages? sessionData;
      List<ChatMessage> loadedMessages = [];
      bool usedTranscript = false;

      debugPrint('[ChatMessagesNotifier] Loading session from server: $sessionId');

      // Also check server for active streams (in case app was restarted/navigated away)
      // This is done in parallel with loading the session for efficiency
      final serverStreamCheckFuture = _service.hasActiveStream(sessionId);

      // Track segment metadata for lazy loading UI
      List<TranscriptSegment> segmentMetadata = [];
      int segmentCount = 0;

      try {
        // First try to get the rich transcript (has tool calls, thinking, etc.)
        // Use afterCompact=true for fast initial load (only recent messages)
        final transcript = await _service.getSessionTranscript(sessionId, afterCompact: true);
        if (transcript != null && transcript.events.isNotEmpty) {
          loadedMessages = transcript.toMessages();
          usedTranscript = true;
          segmentMetadata = transcript.segments;
          segmentCount = transcript.segmentCount;
          debugPrint('[ChatMessagesNotifier] Loaded ${loadedMessages.length} messages from SDK transcript '
              '(${transcript.eventCount} events, ${segmentCount} segments, hasEarlier: ${transcript.hasEarlierSegments})');
        }

        // Get session metadata (we still need this for title, workingDirectory, etc.)
        // Also contains path migration info if the session needs migration
        sessionData = await _service.getSession(sessionId);
        if (sessionData != null) {
          loadedSession = sessionData.session;
          // Only use markdown messages if transcript didn't provide any
          if (!usedTranscript || loadedMessages.isEmpty) {
            loadedMessages = sessionData.messages;
            debugPrint('[ChatMessagesNotifier] Using ${loadedMessages.length} messages from markdown');
          }
        }
      } catch (e) {
        debugPrint('[ChatMessagesNotifier] Server error loading session: $e');
      }

      // Wait for server stream check
      final serverHasActiveStream = await serverStreamCheckFuture;
      debugPrint('[ChatMessagesNotifier] Server stream check result: $serverHasActiveStream (local: $hasActiveStream)');
      if (serverHasActiveStream && !hasActiveStream) {
        debugPrint('[ChatMessagesNotifier] Server reports active stream for: $sessionId (not in local manager)');
        hasActiveStream = true;
      }

      if (loadedSession == null) {
        debugPrint('[ChatMessagesNotifier] ERROR: Session $sessionId not found');
        state = state.copyWith(error: 'Session not found', isLoading: false);
        return;
      }

      // Check if this session continues another - load prior messages
      List<ChatMessage> priorMessages = [];
      ChatSession? continuedFromSession;

      if (loadedSession.continuedFrom != null) {
        debugPrint('[ChatMessagesNotifier] Session continues from: ${loadedSession.continuedFrom}');
        try {
          final originalSessionData = await _service.getSession(loadedSession.continuedFrom!);
          if (originalSessionData != null) {
            priorMessages = originalSessionData.messages;
            continuedFromSession = originalSessionData.session;
            debugPrint('[ChatMessagesNotifier] Loaded ${priorMessages.length} prior messages');
          } else {
            debugPrint('[ChatMessagesNotifier] Could not find original session to load prior messages');
          }
        } catch (e) {
          debugPrint('[ChatMessagesNotifier] Error loading prior messages: $e');
        }
      }

      // SIMPLIFIED: The session id IS the SDK session ID now
      // Just use it directly for all API calls
      debugPrint('[ChatMessagesNotifier] Loading session with ID: $sessionId (usedTranscript: $usedTranscript, serverActive: $serverHasActiveStream)');

      // Preserve state that should persist across session reloads
      final currentModel = state.model;

      // Load persisted contexts from database
      // This ensures contexts survive app restarts and session switches
      List<String> effectiveContexts = state.selectedContexts;
      bool effectiveContextsExplicit = state.contextsExplicitlySet;

      try {
        final persistedContexts = await _service.getSessionContextFolders(sessionId);
        if (persistedContexts.isNotEmpty) {
          effectiveContexts = persistedContexts;
          effectiveContextsExplicit = true;
          debugPrint('[ChatMessagesNotifier] Loaded persisted contexts from database: $persistedContexts');
        } else if (!effectiveContextsExplicit) {
          // No persisted contexts and no local explicit choice - use defaults
          debugPrint('[ChatMessagesNotifier] No persisted contexts, using defaults');
        }
      } catch (e) {
        debugPrint('[ChatMessagesNotifier] Failed to load persisted contexts: $e');
        // Fall back to current state contexts
      }

      // Guard: session may have switched while we were loading async data
      if (state.sessionId != sessionId) {
        debugPrint('[ChatMessagesNotifier] loadSession skipped — session switched to ${state.sessionId}');
        return;
      }

      state = ChatMessagesState(
        messages: loadedMessages,
        sessionId: sessionId,
        sessionTitle: loadedSession.title,
        workingDirectory: loadedSession.workingDirectory,
        viewingSession: loadedSession.archived ? loadedSession : null,
        priorMessages: priorMessages,
        continuedFromSession: continuedFromSession,
        isStreaming: hasActiveStream,
        isLoading: false, // Loading complete
        model: currentModel, // Preserve model from streaming
        transcriptSegments: segmentMetadata,
        transcriptSegmentCount: segmentCount,
        selectedContexts: effectiveContexts, // Use persisted or current contexts
        contextsExplicitlySet: effectiveContextsExplicit, // Mark explicit if loaded from DB
        trustLevel: loadedSession.trustLevel, // Preserve trust level from server
      );

      // If there's an active background stream, reattach to receive updates
      if (_streamManager.hasActiveStream(sessionId)) {
        debugPrint('[ChatMessagesNotifier] Session has active background stream - reattaching');
        _reattachToBackgroundStream(sessionId);
      } else if (serverHasActiveStream) {
        // Server has active stream but we don't have a local one
        // Poll for completion and reload when done
        debugPrint('[ChatMessagesNotifier] Server has active stream - polling for completion');
        _startPollingForStreamCompletion(sessionId);
      }

      trace.end(additionalData: {'messageCount': loadedMessages.length, 'usedTranscript': usedTranscript, 'hasActiveStream': hasActiveStream});
    } catch (e) {
      trace.end(additionalData: {'error': e.toString()});
      _log.error('Error loading session', error: e);
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  /// Load a specific transcript segment (for loading older history on demand)
  ///
  /// [segmentIndex] - The segment to load (0 = oldest, last = most recent)
  /// The segment's messages will be prepended to the current messages.
  Future<void> loadSegment(int segmentIndex) async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    debugPrint('[ChatMessagesNotifier] Loading segment $segmentIndex for session: $sessionId');

    try {
      final transcript = await _service.getSessionTranscript(
        sessionId,
        afterCompact: false,
        segment: segmentIndex,
      );

      if (transcript == null || transcript.events.isEmpty) {
        debugPrint('[ChatMessagesNotifier] No events in segment $segmentIndex');
        return;
      }

      final segmentMessages = transcript.toMessages();
      debugPrint('[ChatMessagesNotifier] Loaded ${segmentMessages.length} messages from segment $segmentIndex');

      // Prepend segment messages to existing messages
      final updatedMessages = [...segmentMessages, ...state.messages];

      // Update segment metadata to mark this segment as loaded
      final updatedSegments = state.transcriptSegments.map((s) {
        if (s.index == segmentIndex) {
          return TranscriptSegment(
            index: s.index,
            isCompacted: s.isCompacted,
            messageCount: s.messageCount,
            eventCount: s.eventCount,
            startTime: s.startTime,
            endTime: s.endTime,
            preview: s.preview,
            loaded: true,
          );
        }
        return s;
      }).toList();

      state = state.copyWith(
        messages: updatedMessages,
        transcriptSegments: updatedSegments,
      );
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Error loading segment $segmentIndex: $e');
    }
  }

  /// Refresh the current session from the server
  ///
  /// Useful when streaming reconnection isn't working - user can manually refresh.
  Future<void> refreshSession() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    debugPrint('[ChatMessagesNotifier] Manually refreshing session: $sessionId');
    await loadSession(sessionId);
  }

  /// Reattach to a background stream to continue receiving updates
  void _reattachToBackgroundStream(String sessionId) {
    _reattachStreamContent.clear(); // Prevent stale content from previous session
    _currentStreamSubscription = _streamManager.reattachCallback(
      sessionId: sessionId,
      onEvent: (event) => _handleStreamEvent(event, sessionId),
      onDone: () {
        debugPrint('[ChatMessagesNotifier] Background stream done for: $sessionId');
        if (state.sessionId == sessionId) {
          state = state.copyWith(isStreaming: false);
          _ref.invalidate(chatSessionsProvider);
        }
      },
      onError: (error) {
        debugPrint('[ChatMessagesNotifier] Background stream error for $sessionId: $error');
        if (state.sessionId == sessionId) {
          state = state.copyWith(isStreaming: false, error: error.toString());
        }
      },
    );
  }

  Timer? _pollTimer;

  /// Poll the server for stream completion when we don't have a local stream
  ///
  /// Polls until the server reports the stream is done, then reloads the
  /// session to get the final content. Caps at 30 ticks (60s) to prevent
  /// indefinite resource drain if server is unreachable.
  void _startPollingForStreamCompletion(String sessionId) {
    debugPrint('[ChatMessagesNotifier] >>> Starting polling for session: $sessionId');
    _pollTimer?.cancel();
    _isPolling = false;
    var tickCount = 0;
    const maxTicks = 30; // 60 seconds at 2s intervals

    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      // Guard: notifier disposed
      if (!mounted) {
        timer.cancel();
        return;
      }

      // Guard: prevent overlapping async callbacks
      if (_isPolling) return;

      tickCount++;

      // Guard: session changed
      if (state.sessionId != sessionId) {
        timer.cancel();
        _pollTimer = null;
        return;
      }

      // Guard: max timeout reached
      if (tickCount >= maxTicks) {
        debugPrint('[ChatMessagesNotifier] Poll timeout after ${maxTicks * 2}s for session: $sessionId');
        timer.cancel();
        _pollTimer = null;
        if (mounted) {
          state = state.copyWith(isStreaming: false);
        }
        return;
      }

      _isPolling = true;
      try {
        final stillActive = await _service.hasActiveStream(sessionId);
        if (!mounted) { timer.cancel(); return; } // Guard after await
        debugPrint('[ChatMessagesNotifier] Polling stream status for $sessionId: active=$stillActive (tick $tickCount/$maxTicks)');

        if (!stillActive) {
          // Stream completed - reload session to get final content
          timer.cancel();
          _pollTimer = null;
          debugPrint('[ChatMessagesNotifier] Server stream completed - reloading session');
          state = state.copyWith(isStreaming: false);
          await loadSession(sessionId);
          if (mounted) {
            _ref.invalidate(chatSessionsProvider);
          }
        } else {
          // Still streaming - reload to get latest content
          final transcript = await _service.getSessionTranscript(sessionId);
          if (!mounted) { timer.cancel(); return; } // Guard after await
          if (transcript != null && transcript.events.isNotEmpty) {
            final messages = transcript.toMessages();
            if (messages.length > state.messages.length) {
              debugPrint('[ChatMessagesNotifier] Got ${messages.length} messages (was ${state.messages.length})');
              state = state.copyWith(messages: messages);
            }
          }
        }
      } catch (e) {
        debugPrint('[ChatMessagesNotifier] Polling error: $e');
        // Don't stop polling on transient errors
      } finally {
        _isPolling = false;
      }
    });
  }

  /// Accumulated content for reattached background streams
  List<MessageContent> _reattachStreamContent = [];

  /// Handle a stream event from background stream reattachment
  ///
  /// Unlike sendMessage which creates the assistant message, this is used when
  /// reattaching to a background stream - we need to append/update content.
  void _handleStreamEvent(StreamEvent event, String sessionId) {
    // Only process if we're still on this session
    if (state.sessionId != sessionId) return;

    switch (event.type) {
      case StreamEventType.session:
        // Capture model info if provided
        debugPrint('[ChatMessagesNotifier] Reattach stream session event');
        break;

      case StreamEventType.model:
        final model = event.model;
        if (model != null) {
          debugPrint('[ChatMessagesNotifier] Reattach stream model: $model');
          state = state.copyWith(model: model);
        }
        break;

      case StreamEventType.promptMetadata:
        // Prompt composition metadata for transparency
        final metadata = PromptMetadata(
          promptSource: event.promptSource ?? 'default',
          promptSourcePath: event.promptSourcePath,
          contextFiles: event.contextFiles,
          contextTokens: event.contextTokens,
          contextTruncated: event.contextTruncated,
          agentName: event.agentName,
          availableAgents: event.availableAgents,
          basePromptTokens: event.basePromptTokens,
          totalPromptTokens: event.totalPromptTokens,
          trustMode: event.trustMode,
        );
        debugPrint('[ChatMessagesNotifier] Reattach stream prompt metadata: ${metadata.promptSource}');
        state = state.copyWith(promptMetadata: metadata);
        break;

      case StreamEventType.text:
        // Text content from server - accumulate it
        final content = event.textContent;
        if (content != null) {
          // Replace or add text content
          final hasTextContent = _reattachStreamContent.any((c) => c.type == ContentType.text);
          if (hasTextContent) {
            final lastTextIndex = _reattachStreamContent.lastIndexWhere(
                (c) => c.type == ContentType.text);
            _reattachStreamContent[lastTextIndex] = MessageContent.text(content);
          } else {
            _reattachStreamContent.add(MessageContent.text(content));
          }
          // Throttle text updates to ~20/sec (same as sendMessage path)
          _updateReattachAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        }
        break;

      case StreamEventType.toolUse:
        // Tool call event — flush pending throttled updates first
        _flushPendingUpdates();
        final toolCall = event.toolCall;
        if (toolCall != null) {
          // Convert any pending text to thinking before tool
          final lastTextIndex = _reattachStreamContent.lastIndexWhere(
              (c) => c.type == ContentType.text);
          if (lastTextIndex >= 0) {
            final thinkingText = _reattachStreamContent[lastTextIndex].text ?? '';
            if (thinkingText.isNotEmpty) {
              _reattachStreamContent[lastTextIndex] = MessageContent.thinking(thinkingText);
            }
          }
          _reattachStreamContent.add(MessageContent.toolUse(toolCall));
          // Force immediate update for tool events (not throttled)
          _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        }
        break;

      case StreamEventType.toolResult:
        // Tool result - update the corresponding tool call
        final toolUseId = event.toolUseId;
        final resultContent = event.toolResultContent;
        if (toolUseId != null && resultContent != null) {
          for (int i = 0; i < _reattachStreamContent.length; i++) {
            final content = _reattachStreamContent[i];
            if (content.type == ContentType.toolUse &&
                content.toolCall?.id == toolUseId) {
              final updatedToolCall = content.toolCall!.withResult(
                resultContent,
                isError: event.toolResultIsError,
              );
              _reattachStreamContent[i] = MessageContent.toolUse(updatedToolCall);
              _updateReattachAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
              break;
            }
          }
        }
        break;

      case StreamEventType.thinking:
        // Extended thinking content
        final thinkingText = event.thinkingContent;
        if (thinkingText != null && thinkingText.isNotEmpty) {
          _reattachStreamContent.add(MessageContent.thinking(thinkingText));
          _updateReattachAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        }
        break;

      case StreamEventType.warning:
        // Non-fatal warning — append as distinct content type (won't be overwritten by text)
        _reattachStreamContent.add(MessageContent.warning(_formatWarningText(event)));
        _updateReattachAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        break;

      case StreamEventType.done:
        _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: false);
        _reattachStreamContent = []; // Reset for next stream
        state = state.copyWith(isStreaming: false);
        // Reload to get final state
        loadSession(sessionId);
        break;

      case StreamEventType.aborted:
        // Stream was stopped by user - session is still valid
        _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: false);
        _reattachStreamContent = [];
        state = state.copyWith(isStreaming: false);
        debugPrint('[ChatMessagesNotifier] Stream aborted: ${event.abortedMessage}');
        // Reload to get current state (conversation continues)
        loadSession(sessionId);
        break;

      case StreamEventType.error:
        _reattachStreamContent = [];
        state = state.copyWith(
          isStreaming: false,
          error: event.errorMessage ?? 'Unknown error',
        );
        break;

      case StreamEventType.typedError:
        // Handle typed errors with recovery info
        _reattachStreamContent = [];
        final typedErr = event.typedError;
        state = state.copyWith(
          isStreaming: false,
          error: typedErr?.message ?? event.errorMessage ?? 'Unknown error',
        );
        break;

      case StreamEventType.userMessage:
        // User message event - add if not already present
        // This ensures the user's message is visible when rejoining mid-stream
        final userContent = event.userMessageContent;
        debugPrint('[ChatMessagesNotifier] Reattach stream: GOT user_message event!');
        debugPrint('[ChatMessagesNotifier] Reattach stream: content="${userContent?.substring(0, (userContent?.length ?? 0) > 50 ? 50 : (userContent?.length ?? 0))}..."');
        debugPrint('[ChatMessagesNotifier] Reattach stream: Current messages count=${state.messages.length}');
        if (userContent != null && userContent.isNotEmpty) {
          // Check if we already have a user message with this exact content (avoid duplicates)
          final hasUserMessage = state.messages.any((m) =>
              m.role == MessageRole.user && m.textContent == userContent);
          debugPrint('[ChatMessagesNotifier] Reattach stream: hasUserMessage=$hasUserMessage');
          if (!hasUserMessage) {
            debugPrint('[ChatMessagesNotifier] Reattach stream: ADDING user message to END of list');
            final userMessage = ChatMessage.user(
              sessionId: sessionId,
              text: userContent,
            );
            // Add user message at the END (after existing messages, before assistant response)
            final updatedMessages = [...state.messages, userMessage];
            debugPrint('[ChatMessagesNotifier] Reattach stream: New messages count=${updatedMessages.length}');
            debugPrint('[ChatMessagesNotifier] Reattach stream: Last message role=${updatedMessages.last.role}');
            state = state.copyWith(
              messages: updatedMessages,
            );
          }
        }
        break;

      case StreamEventType.userQuestion:
        // Restore pendingUserQuestion when reattaching to background stream
        debugPrint('[ChatMessagesNotifier] Restoring user question from reattach: ${event.questionRequestId}');
        state = state.copyWith(
          pendingUserQuestion: {
            'requestId': event.questionRequestId,
            'sessionId': event.sessionId,
            'questions': event.questions,
          },
        );
        break;

      case StreamEventType.init:
      case StreamEventType.sessionUnavailable:
      case StreamEventType.unknown:
        // Ignore these events in join stream
        break;
    }
  }

  /// Update or add an assistant message for joined streams
  ///
  /// Unlike sendMessage, we may be joining mid-stream where the assistant message
  /// already exists, or we may be catching up from buffer where we need to add it.
  void _updateOrAddAssistantMessage(
    List<MessageContent> content,
    String sessionId,
    {required bool isStreaming}
  ) {
    if (content.isEmpty) return;

    final messages = List<ChatMessage>.from(state.messages);
    debugPrint('[ChatMessagesNotifier] _updateOrAddAssistantMessage: messages.length=${messages.length}');
    if (messages.isNotEmpty) {
      debugPrint('[ChatMessagesNotifier] _updateOrAddAssistantMessage: first.role=${messages.first.role}, last.role=${messages.last.role}');
    }

    // Find the last assistant message that is still streaming.
    // If none is streaming, fall back to the very last assistant message.
    // This prevents overwriting a completed response when the server sends
    // a second response to an injected mid-stream message.
    var targetIndex = messages.lastIndexWhere(
      (m) => m.role == MessageRole.assistant && m.isStreaming,
    );
    if (targetIndex == -1) {
      targetIndex = messages.lastIndexWhere(
        (m) => m.role == MessageRole.assistant,
      );
    }
    if (targetIndex != -1) {
      // Update existing assistant message
      messages[targetIndex] = messages[targetIndex].copyWith(
        content: List.from(content),
        isStreaming: isStreaming,
      );
    } else {
      // Need to add a new assistant message
      messages.add(ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        sessionId: sessionId,
        role: MessageRole.assistant,
        content: List.from(content),
        timestamp: DateTime.now(),
        isStreaming: isStreaming,
      ));
    }

    state = state.copyWith(messages: messages);
  }

  /// Throttled version of _updateOrAddAssistantMessage for the reattach path.
  ///
  /// Without throttling, rapid SSE events (~20+/sec) during reattach cause
  /// excessive widget rebuilds.  This uses the same _streamingThrottle as
  /// the primary sendMessage path.
  void _updateReattachAssistantMessage(
    List<MessageContent> content,
    String sessionId,
    {required bool isStreaming}
  ) {
    if (!isStreaming) {
      // Always flush immediately when streaming ends
      _pendingContent = null;
      _pendingSessionId = null;
      _updateOrAddAssistantMessage(content, sessionId, isStreaming: false);
      _streamingThrottle.reset();
      return;
    }

    // Store pending content with session ID so flush routes correctly
    _pendingContent = content;
    _pendingSessionId = sessionId;
    if (_streamingThrottle.shouldProceed()) {
      _updateOrAddAssistantMessage(content, sessionId, isStreaming: true);
    }
  }

  /// Abort the current streaming session
  ///
  /// Sends abort signal to the server to stop the agent mid-processing.
  /// Returns true if abort was successful.
  Future<bool> abortStream() async {
    final sessionId = state.sessionId;
    if (sessionId == null || !state.isStreaming) {
      debugPrint('[ChatMessagesNotifier] No active stream to abort');
      return false;
    }

    debugPrint('[ChatMessagesNotifier] Aborting stream for: $sessionId');
    final success = await _service.abortStream(sessionId);

    if (success) {
      // Update state to reflect abort
      state = state.copyWith(isStreaming: false);
      // Cancel local subscription
      _currentStreamSubscription?.cancel();
      _currentStreamSubscription = null;
      _activeStreamSessionId = null;
    }

    return success;
  }

  /// Clean up resources when notifier is disposed
  @override
  void dispose() {
    _resetTransientState();
    super.dispose();
  }

  /// Clear current session (for new chat)
  ///
  /// Also cancels any active stream by invalidating the stream session ID.
  /// Preserves workingDirectory if [preserveWorkingDirectory] is true.
  /// Note: Background streams continue even when session is cleared.
  void clearSession({bool preserveWorkingDirectory = false}) {
    _resetTransientState();

    if (preserveWorkingDirectory && state.workingDirectory != null) {
      state = ChatMessagesState(workingDirectory: state.workingDirectory);
    } else {
      state = const ChatMessagesState();
    }
  }

  /// Set the working directory for new sessions
  ///
  /// [path] should be relative to the vault (e.g., "Chat", "Projects/myapp")
  /// Set to null or 'Chat' for the default thinking-oriented experience.
  void setWorkingDirectory(String? path) {
    state = state.copyWith(
      workingDirectory: path,
      clearWorkingDirectory: path == null,
    );
  }

  /// Update the selected context files for this session
  ///
  /// Changes take effect on the next message sent.
  /// [contexts] are paths relative to vault (e.g., "Chat/contexts/work-context.md")
  /// This also marks contexts as explicitly set, so even an empty list means "load nothing".
  /// Also persists the selection to the database for the current session.
  void setSelectedContexts(List<String> contexts) {
    state = state.copyWith(
      selectedContexts: contexts,
      contextsExplicitlySet: true,
    );

    // Persist to database if we have a session
    _persistContextsToDatabase(contexts);
  }

  /// Toggle a specific context file on or off
  void toggleContext(String contextPath) {
    final current = List<String>.from(state.selectedContexts);
    if (current.contains(contextPath)) {
      current.remove(contextPath);
    } else {
      current.add(contextPath);
    }
    state = state.copyWith(
      selectedContexts: current,
      contextsExplicitlySet: true,
    );

    // Persist to database if we have a session
    _persistContextsToDatabase(current);
  }

  /// Persist context selection to database for the current session
  Future<void> _persistContextsToDatabase(List<String> contexts) async {
    final sessionId = state.sessionId;
    if (sessionId == null || sessionId == 'pending') {
      debugPrint('[ChatMessagesNotifier] No session ID yet, contexts will be persisted after first message');
      return;
    }

    try {
      await _service.setSessionContextFolders(sessionId, contexts);
      debugPrint('[ChatMessagesNotifier] Persisted contexts to database: $contexts');
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Failed to persist contexts: $e');
      // Don't rethrow - local state is still updated, persistence is best-effort
    }
  }

  /// Mark that CLAUDE.md should be reloaded on the next message
  ///
  /// This is useful when the working directory's CLAUDE.md has been updated
  /// and the user wants to incorporate the changes without starting a new session.
  void markClaudeMdForReload() {
    state = state.copyWith(reloadClaudeMd: true);
  }

  /// Clear the reload CLAUDE.md flag (called after sending a message)
  void _clearReloadClaudeMdFlag() {
    if (state.reloadClaudeMd) {
      state = state.copyWith(reloadClaudeMd: false);
    }
  }

  /// Set up a continuation from an existing session
  ///
  /// This prepares the chat state to continue from an imported or prior session.
  /// The prior messages are stored for display in the resume marker,
  /// and will be passed as context with the first message.
  void setupContinuation({
    required ChatSession originalSession,
    required List<ChatMessage> priorMessages,
  }) {
    debugPrint('[ChatMessagesNotifier] setupContinuation called');
    debugPrint('[ChatMessagesNotifier] Original session: ${originalSession.id}');
    debugPrint('[ChatMessagesNotifier] Prior messages: ${priorMessages.length}');
    if (priorMessages.isNotEmpty) {
      debugPrint('[ChatMessagesNotifier] First prior message: ${priorMessages.first.textContent.substring(0, (priorMessages.first.textContent.length).clamp(0, 100))}...');
    }
    state = ChatMessagesState(
      continuedFromSession: originalSession,
      priorMessages: priorMessages,
    );
    debugPrint('[ChatMessagesNotifier] State set - isContinuation: ${state.isContinuation}');
  }

  /// Format prior messages as context for the AI
  /// The server wraps this in its own header, so we just provide the messages
  /// Limited to ~50k chars to avoid 413 errors
  String _formatPriorMessagesAsContext() {
    if (state.priorMessages.isEmpty) return '';

    final buffer = StringBuffer();
    const maxChars = 50000;

    // Take most recent messages that fit within limit
    final messages = state.priorMessages.reversed.toList();
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

    debugPrint('[ChatMessagesNotifier] Formatted ${selectedMessages.length}/${state.priorMessages.length} prior messages ($totalChars chars)');
    return buffer.toString().trim();
  }

  /// Inject a message into an active streaming session.
  ///
  /// Send a message and handle streaming response
  ///
  /// [systemPrompt] - Custom system prompt for this session
  /// If not provided, the server will use the module's CLAUDE.md or default prompt.
  ///
  /// [priorConversation] - For continued conversations, prior messages
  /// formatted as text. Goes into system prompt, not shown in chat.
  ///
  /// [contexts] - List of context file paths to load (e.g., ['Chat/contexts/general-context.md'])
  /// Only used on first message of a new chat.
  Future<void> sendMessage({
    required String message,
    String? systemPrompt,
    String? initialContext,
    String? priorConversation,
    List<String>? contexts,
    List<ChatAttachment>? attachments,
    String? agentType,
    String? agentPath,
    String? trustLevel,
    String? workspaceId,
  }) async {
    if (state.isStreaming) {
      // Defer: don't show the user message until the current stream finishes.
      // Showing it immediately creates a jarring visual where the new user
      // message floats above a still-streaming assistant response.
      // The message will be flushed from _queuedMessages on the done event.
      debugPrint('[ChatMessagesNotifier] sendMessage deferred (streaming active): "$message"');
      _queuedMessages.add(message);
      return;
    }

    // Use existing session ID if we have one, otherwise let the server assign one
    // DON'T generate our own UUID - the SDK session ID is the source of truth
    final existingSessionId = state.sessionId;
    final isNewSession = existingSessionId == null;
    debugPrint('[ChatMessagesNotifier] sendMessage: existingSessionId=$existingSessionId, isNew=$isNewSession');

    // Build display text including attachment info
    String displayText = message;
    if (attachments != null && attachments.isNotEmpty) {
      final attachmentLines = attachments.map((att) {
        final icon = switch (att.type) {
          AttachmentType.image => '🖼️',
          AttachmentType.pdf => '📄',
          AttachmentType.text => '📝',
          AttachmentType.code => '💻',
          AttachmentType.archive => '📦',
          AttachmentType.audio => '🎵',
          AttachmentType.video => '🎬',
          AttachmentType.unknown => '📎',
        };
        return '$icon ${att.fileName} (${att.formattedSize})';
      }).join('\n');

      if (message.isNotEmpty) {
        displayText = '$message\n\n**Attachments:**\n$attachmentLines';
      } else {
        displayText = '**Attachments:**\n$attachmentLines';
      }
    }

    // For new sessions, use 'pending' as a placeholder until server assigns real ID
    // For existing sessions, use the real ID
    // Note: This is mutable because it gets updated when the server assigns the real session ID
    var displaySessionId = existingSessionId ?? 'pending';

    // Add user message immediately
    final userMessage = ChatMessage.user(
      sessionId: displaySessionId,
      text: displayText,
    );

    // Create placeholder for assistant response
    final assistantMessage = ChatMessage.assistantPlaceholder(
      sessionId: displaySessionId,
    );

    // Mark this session as the active stream (will be updated when we get real ID)
    _activeStreamSessionId = displaySessionId;

    state = state.copyWith(
      messages: [...state.messages, userMessage, assistantMessage],
      isStreaming: true,
      sessionId: displaySessionId,
      error: null,
      trustLevel: trustLevel ?? state.trustLevel,
    );

    // Include prior conversation context if this is a continuation
    // This goes into the system prompt, not shown in the user message
    String? effectivePriorConversation = priorConversation;
    debugPrint('[ChatMessagesNotifier] sendMessage - isContinuation: ${state.isContinuation}');
    debugPrint('[ChatMessagesNotifier] sendMessage - messages.length: ${state.messages.length}');
    debugPrint('[ChatMessagesNotifier] sendMessage - priorMessages.length: ${state.priorMessages.length}');
    if (state.isContinuation && state.messages.length <= 2) {
      // Only inject prior context on first message of continuation
      debugPrint('[ChatMessagesNotifier] Injecting prior conversation context');
      final formatted = _formatPriorMessagesAsContext();
      if (formatted.isNotEmpty) {
        effectivePriorConversation = formatted;
        debugPrint('[ChatMessagesNotifier] Formatted context length: ${effectivePriorConversation.length}');
      } else {
        debugPrint('[ChatMessagesNotifier] WARNING: Prior messages formatted to empty string!');
      }
    } else {
      debugPrint('[ChatMessagesNotifier] NOT injecting prior context (isContinuation: ${state.isContinuation}, messages: ${state.messages.length})');
    }

    try {
      // Get continuedFrom ID for first message of continuation (for persistence)
      final continuedFromId = (state.isContinuation && state.messages.length <= 2)
          ? state.continuedFromSession?.id
          : null;
      debugPrint('[ChatMessagesNotifier] continuedFromId: $continuedFromId');
      if (state.isContinuation) {
        debugPrint('[ChatMessagesNotifier] continuedFromSession.id: ${state.continuedFromSession?.id}');
      }

      // Use provided contexts, or fall back to session's selected contexts
      // This allows mid-session context changes to take effect
      //
      // Key distinction:
      // - contexts param provided: use it (from new chat sheet)
      // - contextsExplicitlySet: user made a choice via settings, use selectedContexts (even if empty)
      // - neither: send null to let server use defaults
      List<String>? effectiveContexts;
      if (contexts != null) {
        effectiveContexts = contexts;
      } else if (state.contextsExplicitlySet) {
        // User explicitly configured contexts - use their choice, even if empty
        effectiveContexts = state.selectedContexts;
      } else {
        // No explicit choice - let server use defaults
        effectiveContexts = null;
      }
      debugPrint('[ChatMessagesNotifier] Using contexts: $effectiveContexts (explicitlySet: ${state.contextsExplicitlySet})');

      // Clear the reload flag after capturing it (will be cleared on successful send)
      final shouldReloadClaudeMd = state.reloadClaudeMd;
      if (shouldReloadClaudeMd) {
        debugPrint('[ChatMessagesNotifier] Reload CLAUDE.md flag is set');
        // Note: Server doesn't yet support a reload flag, but contexts are re-loaded each message
        // The CLAUDE.md is always read fresh from disk on each message
      }
      _clearReloadClaudeMdFlag();

      // Read model preference
      final modelPref = _ref.read(modelPreferenceProvider).valueOrNull;
      final modelApiValue = modelPref?.apiValue;

      // Read active workspace - prefer explicit param, fall back to sidebar filter
      final activeWorkspace = workspaceId ?? _ref.read(activeWorkspaceProvider);

      // Create stream context to hold mutable state across callbacks
      final ctx = _SendStreamContext(
        displaySessionId: displaySessionId,
        originalMessage: message,
      );
      _sendStreamCtx = ctx;

      // Get the raw SSE stream
      final stream = _service.streamChat(
        sessionId: existingSessionId,  // null for new sessions, real ID for existing
        message: message,
        systemPrompt: systemPrompt,
        initialContext: initialContext,
        priorConversation: effectivePriorConversation,
        continuedFrom: continuedFromId,
        workingDirectory: state.workingDirectory,
        contexts: effectiveContexts,
        attachments: attachments,
        agentType: agentType,
        agentPath: agentPath,
        trustLevel: trustLevel,
        model: modelApiValue,
        workspaceId: activeWorkspace,
      );

      // Register with BackgroundStreamManager — this keeps the HTTP
      // connection alive even when the user navigates away.
      _currentStreamSubscription = _streamManager.registerStream(
        sessionId: displaySessionId,
        stream: stream,
        onEvent: (event) => _handleSendStreamEvent(event, ctx),
        onDone: () => _onSendStreamDone(ctx),
        onError: (error) => _onSendStreamError(error, ctx),
      );
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Stream setup error: $e');
      // Only update UI if this is still the active session
      if (_activeStreamSessionId == displaySessionId) {
        state = state.copyWith(
          isStreaming: false,
          error: e.toString(),
        );
      }
      _sendStreamCtx = null;
    }
  }

  /// Handle events from a sendMessage stream (registered with BackgroundStreamManager).
  ///
  /// This is the callback version of what was previously the `await for` body
  /// inside sendMessage().  Events only arrive here while the UI subscription
  /// is active — when the user switches sessions, the subscription is cancelled
  /// and events continue to be consumed by BackgroundStreamManager silently.
  void _handleSendStreamEvent(StreamEvent event, _SendStreamContext ctx) {
    // Guard: only update UI if this session is still in foreground
    if (_activeStreamSessionId != ctx.displaySessionId) return;

    switch (event.type) {
      case StreamEventType.session:
        // Server may return a different session ID (for resumed sessions)
        // For new sessions, this will be null - real ID comes in done event
        final eventSessionId = event.sessionId;
        // Validate session ID - reject "pending" or empty values
        final isValidEventSessionId = eventSessionId != null &&
            eventSessionId.isNotEmpty &&
            eventSessionId != 'pending';

        if (isValidEventSessionId) {
          ctx.actualSessionId = eventSessionId;
          if (eventSessionId != ctx.displaySessionId) {
            // Update session ID if server assigned a different one (always true for new sessions)
            debugPrint('[ChatMessagesNotifier] Session event has server ID: ${ctx.actualSessionId} (was: ${ctx.displaySessionId})');
            _ref.read(currentSessionIdProvider.notifier).state = ctx.actualSessionId;
            // Exit new chat mode now that we have a real session
            _ref.read(newChatModeProvider.notifier).state = false;
            // ALSO update state.sessionId so future sendMessage calls use the correct ID
            state = state.copyWith(sessionId: ctx.actualSessionId);
            // Update the active stream ID to match the real session ID
            _activeStreamSessionId = ctx.actualSessionId;
            // Update the manager's tracking so reattach works with the real ID
            _streamManager.updateSessionId(ctx.displaySessionId, ctx.actualSessionId!);
            // CRITICAL: Also update displaySessionId so subsequent events route correctly
            ctx.displaySessionId = ctx.actualSessionId!;
          }
          // Refresh sessions list now that we have a valid session ID
          // (The session should now exist in the server's database)
          _ref.invalidate(chatSessionsProvider);
        } else {
          debugPrint('[ChatMessagesNotifier] Session event has no valid session ID (new session) - will get ID from done event');
          // Don't refresh session list yet - session not created on server
        }
        // Capture trust level from session event
        final eventTrustLevel = event.trustLevel;
        if (eventTrustLevel != null && eventTrustLevel.isNotEmpty) {
          state = state.copyWith(trustLevel: eventTrustLevel);
        }
        // Capture session title if present
        final sessionTitle = event.sessionTitle;
        if (sessionTitle != null && sessionTitle.isNotEmpty) {
          state = state.copyWith(sessionTitle: sessionTitle);
        }
        // Capture session resume info
        final resumeInfo = event.sessionResumeInfo;
        if (resumeInfo != null) {
          debugPrint('[ChatMessagesNotifier] Session resume info: ${resumeInfo.method} '
              '(sdkResumeFailed: ${resumeInfo.sdkResumeFailed}, '
              'contextInjected: ${resumeInfo.contextInjected}, '
              'messagesInjected: ${resumeInfo.messagesInjected})');
          state = state.copyWith(sessionResumeInfo: resumeInfo);
        }
        break;

      case StreamEventType.model:
        // Model info from SDK - capture for display
        final model = event.model;
        if (model != null) {
          debugPrint('[ChatMessagesNotifier] Using model: $model');
          state = state.copyWith(model: model);
        }
        break;

      case StreamEventType.promptMetadata:
        // Prompt composition metadata for transparency
        final metadata = PromptMetadata(
          promptSource: event.promptSource ?? 'default',
          promptSourcePath: event.promptSourcePath,
          contextFiles: event.contextFiles,
          contextTokens: event.contextTokens,
          contextTruncated: event.contextTruncated,
          agentName: event.agentName,
          availableAgents: event.availableAgents,
          basePromptTokens: event.basePromptTokens,
          totalPromptTokens: event.totalPromptTokens,
          trustMode: event.trustMode,
        );
        debugPrint('[ChatMessagesNotifier] Prompt metadata: ${metadata.promptSource} '
            '(${metadata.totalPromptTokens} tokens, ${metadata.contextFiles.length} context files)');
        state = state.copyWith(promptMetadata: metadata);
        break;

      case StreamEventType.text:
        // Accumulating text content from server
        final content = event.textContent;
        if (content != null) {
          // Track the current text for potential conversion to "thinking"
          // The server sends accumulated text, so we replace the last text block
          final hasTextContent = ctx.accumulatedContent.any((c) => c.type == ContentType.text);
          if (hasTextContent) {
            // Replace the last text content
            final lastTextIndex = ctx.accumulatedContent.lastIndexWhere(
                (c) => c.type == ContentType.text);
            ctx.accumulatedContent[lastTextIndex] = MessageContent.text(content);
          } else {
            ctx.accumulatedContent.add(MessageContent.text(content));
          }
          _updateAssistantMessage(ctx.accumulatedContent, isStreaming: true);
        }
        break;

      case StreamEventType.toolUse:
        // Flush any pending UI updates before showing tool call
        _flushPendingUpdates();

        // Tool call event - convert any pending text to "thinking"
        final toolCall = event.toolCall;
        if (toolCall != null) {
          // Check if there's text content before this tool call
          final lastTextIndex = ctx.accumulatedContent.lastIndexWhere(
              (c) => c.type == ContentType.text);
          if (lastTextIndex >= 0) {
            // Convert the last text block to thinking
            final thinkingText = ctx.accumulatedContent[lastTextIndex].text ?? '';
            if (thinkingText.isNotEmpty) {
              ctx.accumulatedContent[lastTextIndex] = MessageContent.thinking(thinkingText);
            }
          }
          ctx.accumulatedContent.add(MessageContent.toolUse(toolCall));
          // Force immediate update for tool events (not throttled)
          _performMessageUpdate(ctx.accumulatedContent, isStreaming: true);
        }
        break;

      case StreamEventType.toolResult:
        // Tool result - attach to the corresponding tool call
        final toolUseId = event.toolUseId;
        final resultContent = event.toolResultContent;
        if (toolUseId != null && resultContent != null) {
          // Find the tool call with this ID and update it with the result
          for (int i = 0; i < ctx.accumulatedContent.length; i++) {
            final content = ctx.accumulatedContent[i];
            if (content.type == ContentType.toolUse &&
                content.toolCall?.id == toolUseId) {
              // Replace with updated tool call that has the result
              final updatedToolCall = content.toolCall!.withResult(
                resultContent,
                isError: event.toolResultIsError,
              );
              ctx.accumulatedContent[i] = MessageContent.toolUse(updatedToolCall);
              _updateAssistantMessage(ctx.accumulatedContent, isStreaming: true);
              break;
            }
          }
        }
        break;

      case StreamEventType.done:
        // Stream complete
        debugPrint('[ChatMessagesNotifier] Done event received (sessionId: ${ctx.displaySessionId})');

        // Foreground: update UI normally
        _updateAssistantMessage(ctx.accumulatedContent, isStreaming: false);

        // CRITICAL: Capture session ID from done event (for new sessions, this is the first time we get the real ID)
        final doneSessionId = event.sessionId;
        // Validate session ID - reject "pending" or empty values
        final isValidSessionId = doneSessionId != null &&
            doneSessionId.isNotEmpty &&
            doneSessionId != 'pending';

        if (isValidSessionId && doneSessionId != ctx.actualSessionId) {
          debugPrint('[ChatMessagesNotifier] Done event has new session ID: $doneSessionId (was: ${ctx.actualSessionId})');
          ctx.actualSessionId = doneSessionId;
          _ref.read(currentSessionIdProvider.notifier).state = doneSessionId;
          // ALSO update state.sessionId so future sendMessage calls use the correct ID
          state = state.copyWith(sessionId: doneSessionId);

          // Persist any explicitly set contexts now that we have a real session ID
          // This handles the case where user set contexts before the first message
          if (state.contextsExplicitlySet) {
            _persistContextsToDatabase(state.selectedContexts);
          }
        } else if (!isValidSessionId) {
          debugPrint('[ChatMessagesNotifier] WARNING: Done event has invalid session ID: $doneSessionId - keeping current: ${state.sessionId}');
        }

        // Capture session title if present in done event
        final doneTitle = event.sessionTitle;
        // Also capture resume info from done event (may have more complete info)
        final doneResumeInfo = event.sessionResumeInfo;
        if (doneResumeInfo != null) {
          debugPrint('[ChatMessagesNotifier] Done event resume info: ${doneResumeInfo.method}');
          state = state.copyWith(
            isStreaming: false,
            sessionTitle: (doneTitle != null && doneTitle.isNotEmpty) ? doneTitle : null,
            sessionResumeInfo: doneResumeInfo,
          );
        } else if (doneTitle != null && doneTitle.isNotEmpty) {
          state = state.copyWith(isStreaming: false, sessionTitle: doneTitle);
        } else {
          state = state.copyWith(isStreaming: false);
        }
        // Always refresh sessions list to get updated title
        _ref.invalidate(chatSessionsProvider);

        // Flush any queued messages (submitted while streaming was active).
        // Also handle the legacy single-message resend path.
        final pending = List<String>.from(_queuedMessages);
        _queuedMessages.clear();
        if (_pendingResendMessage != null) {
          pending.insert(0, _pendingResendMessage!);
          _pendingResendMessage = null;
        }
        if (pending.isNotEmpty) {
          Future.microtask(() async {
            for (final msg in pending) {
              await sendMessage(message: msg);
            }
          });
        }
        _sendStreamCtx = null;
        break;

      case StreamEventType.error:
        final errorMsg = event.errorMessage ?? 'Unknown error';
        // Foreground: show error to user
        state = state.copyWith(
          isStreaming: false,
          error: errorMsg,
        );
        // Append error to existing content instead of replacing everything
        // This preserves thinking/tool progress that was shown before the error
        ctx.accumulatedContent.add(MessageContent.text('\n\n⚠️ Error: $errorMsg'));
        _updateAssistantMessage(ctx.accumulatedContent, isStreaming: false);
        _sendStreamCtx = null;
        break;

      case StreamEventType.typedError:
        // Typed error with recovery info
        final typedErr = event.typedError;
        final errorMsg = typedErr?.message ?? event.errorMessage ?? 'Unknown error';
        if (typedErr != null) {
          _log.error('Stream typed error: code=${typedErr.code}, '
              'canRetry=${typedErr.canRetry}, '
              'originalError=${typedErr.originalError}',
              error: errorMsg);
        }
        state = state.copyWith(
          isStreaming: false,
          error: errorMsg,
        );
        ctx.accumulatedContent.add(MessageContent.text('\n\n⚠️ Error: $errorMsg'));
        _updateAssistantMessage(ctx.accumulatedContent, isStreaming: false);
        _sendStreamCtx = null;
        break;

      case StreamEventType.warning:
        // Non-fatal warning — append as distinct content type (won't be overwritten by text)
        ctx.accumulatedContent.add(MessageContent.warning(_formatWarningText(event)));
        _updateAssistantMessage(ctx.accumulatedContent, isStreaming: true);
        break;

      case StreamEventType.thinking:
        // Extended thinking content from Claude
        final thinkingText = event.thinkingContent;
        if (thinkingText != null && thinkingText.isNotEmpty) {
          ctx.accumulatedContent.add(MessageContent.thinking(thinkingText));
          _updateAssistantMessage(ctx.accumulatedContent, isStreaming: true);
        }
        break;

      case StreamEventType.sessionUnavailable:
        // SDK session couldn't be resumed - ask user how to proceed
        debugPrint('[ChatMessagesNotifier] Session unavailable');
        final unavailableInfo = SessionUnavailableInfo(
          sessionId: event.sessionId ?? ctx.actualSessionId ?? '',
          reason: event.unavailableReason ?? 'unknown',
          hasMarkdownHistory: event.hasMarkdownHistory,
          messageCount: event.markdownMessageCount,
          message: event.unavailableMessage ?? 'Session could not be resumed.',
          pendingMessage: ctx.originalMessage,
        );
        state = state.copyWith(
          isStreaming: false,
          sessionUnavailable: unavailableInfo,
        );
        debugPrint('[ChatMessagesNotifier] Session unavailable: ${unavailableInfo.reason}');
        _sendStreamCtx = null;
        break;

      case StreamEventType.aborted:
        // Stream was stopped by user - session is still valid for future messages
        debugPrint('[ChatMessagesNotifier] Stream aborted (sessionId: ${ctx.displaySessionId})');
        _updateAssistantMessage(ctx.accumulatedContent, isStreaming: false);
        state = state.copyWith(isStreaming: false);
        // Reload session to get the final state (use actual ID if we have it)
        if (ctx.actualSessionId != null) {
          loadSession(ctx.actualSessionId!);
        }
        _sendStreamCtx = null;
        break;

      case StreamEventType.userMessage:
        // User message event - we already added it locally, so ignore
        debugPrint('[ChatMessagesNotifier] Received user_message event (already displayed locally)');
        break;

      case StreamEventType.userQuestion:
        // User question event - Claude is asking the user something
        // Update state so UI can display the question card
        debugPrint('[ChatMessagesNotifier] Received user_question event: ${event.questionRequestId}');
        state = state.copyWith(
          pendingUserQuestion: {
            'requestId': event.questionRequestId,
            'sessionId': event.sessionId,
            'questions': event.questions,
          },
        );
        break;

      case StreamEventType.init:
      case StreamEventType.unknown:
        // Ignore init and unknown events
        break;
    }
  }

  /// Called when the BackgroundStreamManager reports the stream is done.
  ///
  /// This fires when the stream completes naturally (the done/error/aborted
  /// terminal event was already processed by _handleSendStreamEvent if we
  /// were still subscribed, OR silently consumed by the manager if we were
  /// backgrounded).
  void _onSendStreamDone(_SendStreamContext ctx) {
    debugPrint('[ChatMessagesNotifier] Stream done callback for: ${ctx.displaySessionId}');
    if (!mounted) return;
    // If we're still viewing this session and streaming wasn't already stopped
    // by a terminal event, clean up now.
    if (state.sessionId == ctx.displaySessionId && state.isStreaming) {
      state = state.copyWith(isStreaming: false);
    }
    _ref.invalidate(chatSessionsProvider);
    if (_sendStreamCtx == ctx) _sendStreamCtx = null;
  }

  /// Called when the BackgroundStreamManager reports a stream error.
  ///
  /// Only acts if streaming is still active — if a terminal event
  /// (error/typedError/done) was already processed by [_handleSendStreamEvent],
  /// this is a no-op to prevent double-reporting errors to the user.
  void _onSendStreamError(Object error, _SendStreamContext ctx) {
    debugPrint('[ChatMessagesNotifier] Stream error callback for ${ctx.displaySessionId}: $error');
    if (_activeStreamSessionId == ctx.displaySessionId && state.isStreaming) {
      state = state.copyWith(
        isStreaming: false,
        error: error.toString(),
      );
      ctx.accumulatedContent.add(MessageContent.text('\n\n⚠️ Error: $error'));
      _updateAssistantMessage(ctx.accumulatedContent, isStreaming: false);
    }
    if (_sendStreamCtx == ctx) _sendStreamCtx = null;
  }

  /// Update the assistant message being streamed
  /// Uses throttling during streaming to reduce UI updates
  void _updateAssistantMessage(List<MessageContent> content, {required bool isStreaming}) {
    // Always update immediately when streaming ends
    if (!isStreaming) {
      _pendingContent = null;
      _pendingSessionId = null;
      _performMessageUpdate(content, isStreaming: false);
      _streamingThrottle.reset();
      return;
    }

    // Store pending content (null sessionId = sendMessage path)
    _pendingContent = content;
    _pendingSessionId = null;

    // Throttle UI updates during streaming
    if (_streamingThrottle.shouldProceed()) {
      _performMessageUpdate(content, isStreaming: true);
    }
  }

  /// Actually perform the message update (called from throttled path)
  void _performMessageUpdate(List<MessageContent> content, {required bool isStreaming}) {
    final trace = _perf.trace('MessageUpdate', metadata: {
      'messageCount': state.messages.length,
      'contentBlocks': content.length,
    });

    final messages = List<ChatMessage>.from(state.messages);
    if (messages.isEmpty) {
      trace.end();
      return;
    }

    // Find the last streaming assistant message first, then fall back to
    // the last assistant message by role. This prevents overwriting a
    // completed response when mid-stream injection triggers a second response.
    var targetIndex = messages.lastIndexWhere(
      (m) => m.role == MessageRole.assistant && m.isStreaming,
    );
    if (targetIndex == -1) {
      targetIndex = messages.lastIndexWhere(
        (m) => m.role == MessageRole.assistant,
      );
    }
    if (targetIndex == -1) {
      trace.end();
      return;
    }

    messages[targetIndex] = messages[targetIndex].copyWith(
      content: List.from(content),
      isStreaming: isStreaming,
    );

    state = state.copyWith(messages: messages);
    trace.end();
  }

  /// Flush any pending content updates (call when important events happen).
  ///
  /// Routes through the correct update method based on which path stored
  /// the pending content: reattach path (has session ID) vs sendMessage path.
  void _flushPendingUpdates() {
    if (_pendingContent != null) {
      if (_pendingSessionId != null) {
        _updateOrAddAssistantMessage(_pendingContent!, _pendingSessionId!, isStreaming: true);
      } else {
        _performMessageUpdate(_pendingContent!, isStreaming: true);
      }
    }
  }

  /// Handle user's choice for session recovery
  /// Called when user selects how to proceed after session_unavailable
  ///
  /// [recoveryMode] - Either 'inject_context' or 'fresh_start'
  Future<void> recoverSession(String recoveryMode) async {
    final unavailableInfo = state.sessionUnavailable;
    if (unavailableInfo == null) {
      debugPrint('[ChatMessagesNotifier] recoverSession called but no unavailable info');
      return;
    }

    debugPrint('[ChatMessagesNotifier] Recovering session with mode: $recoveryMode');

    // Clear the unavailable state
    state = state.copyWith(clearSessionUnavailable: true);

    // If fresh start, also clear the session ID to get a new one
    if (recoveryMode == 'fresh_start') {
      state = state.copyWith(
        sessionId: null,
        messages: [],
        clearSessionUnavailable: true,
      );
    }

    // Retry the original message
    await sendMessage(message: unavailableInfo.pendingMessage);
  }

  /// Dismiss the session unavailable dialog without retrying
  void dismissSessionUnavailable() {
    state = state.copyWith(clearSessionUnavailable: true);
  }

  /// Answer a pending user question (from AskUserQuestion tool)
  ///
  /// [answers] is a map of question -> answer(s)
  /// Returns true if the answer was successfully submitted
  Future<bool> answerQuestion(Map<String, dynamic> answers) async {
    final pending = state.pendingUserQuestion;
    if (pending == null) {
      debugPrint('[ChatMessagesNotifier] No pending user question to answer');
      return false;
    }

    final sessionId = pending['sessionId'] as String?;
    final requestId = pending['requestId'] as String?;
    if (sessionId == null || requestId == null) {
      debugPrint('[ChatMessagesNotifier] Missing sessionId or requestId in pending question');
      return false;
    }

    debugPrint('[ChatMessagesNotifier] Answering question $requestId with: $answers');

    try {
      final success = await _service.answerQuestion(
        sessionId: sessionId,
        requestId: requestId,
        answers: answers,
      );

      if (success) {
        // Clear the pending question
        state = state.copyWith(clearPendingUserQuestion: true);
        debugPrint('[ChatMessagesNotifier] Question answered successfully');
      } else {
        // Backend likely timed out — clear the stale floating card.
        // The inline card in the transcript will show the correct status
        // when the session is reloaded.
        debugPrint('[ChatMessagesNotifier] Answer rejected (question likely expired), clearing');
        state = state.copyWith(clearPendingUserQuestion: true);
      }

      return success;
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Error answering question: $e');
      return false;
    }
  }

  /// Dismiss the pending user question without answering
  void dismissPendingQuestion() {
    state = state.copyWith(clearPendingUserQuestion: true);
  }
}

/// Provider for chat messages state
final chatMessagesProvider =
    StateNotifierProvider<ChatMessagesNotifier, ChatMessagesState>((ref) {
  final service = ref.watch(chatServiceProvider);
  final streamManager = ref.watch(backgroundStreamManagerProvider);
  final notifier = ChatMessagesNotifier(service, streamManager, ref);
  return notifier;
});
