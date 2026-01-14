import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import '../models/context_file.dart';
import '../models/context_folder.dart';
import '../models/stream_event.dart';
import '../models/session_resume_info.dart';
import '../models/prompt_metadata.dart';
import '../models/vault_entry.dart';
import '../models/session_transcript.dart';
import '../models/curator_session.dart';
import '../models/attachment.dart';
import '../services/chat_service.dart';
import '../services/local_session_reader.dart';
import '../services/chat_import_service.dart';
import '../services/background_stream_manager.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/services/performance_service.dart';

// ============================================================
// Service Provider
// ============================================================

// Note: aiServerUrlProvider is imported from feature_flags_provider.dart
// Do NOT redefine it here - that was causing the URL not to update bug!

/// Provider for ChatService
///
/// Creates a new ChatService instance with the configured server URL and API key.
/// The service handles all communication with the parachute-agent backend.
final chatServiceProvider = Provider<ChatService>((ref) {
  // Watch the server URL - this will rebuild ChatService when URL changes
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';

  // Watch the API key - this will rebuild ChatService when key changes
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = ChatService(baseUrl: baseUrl, apiKey: apiKey);

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// Provider for the local session reader (reads from vault markdown files)
final localSessionReaderProvider = Provider<LocalSessionReader>((ref) {
  return LocalSessionReader(FileSystemService.chat());
});

/// Provider for the chat import service
///
/// Used to import chat history from ChatGPT, Claude, and other sources.
final chatImportServiceProvider = Provider<ChatImportService>((ref) {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  return ChatImportService(fileSystemService);
});

// ============================================================
// Session Providers
// ============================================================

/// Provider for fetching all chat sessions (non-archived only)
///
/// Tries to fetch from the server first. If server is unavailable,
/// falls back to reading local session files from the vault.
final chatSessionsProvider = FutureProvider<List<ChatSession>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  final localReader = ref.watch(localSessionReaderProvider);

  try {
    // Try server first - gets non-archived sessions by default
    final serverSessions = await service.getSessions();
    debugPrint('[ChatProviders] Loaded ${serverSessions.length} sessions from server');
    return serverSessions;
  } catch (e) {
    debugPrint('[ChatProviders] Server unavailable, falling back to local sessions: $e');

    // Fall back to local sessions
    try {
      final localSessions = await localReader.getLocalSessions();
      debugPrint('[ChatProviders] Loaded ${localSessions.length} local sessions');
      return localSessions.where((s) => !s.archived).toList();
    } catch (localError) {
      debugPrint('[ChatProviders] Error loading local sessions: $localError');
      return [];
    }
  }
});

/// Provider for fetching archived chat sessions
final archivedSessionsProvider = FutureProvider<List<ChatSession>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  final localReader = ref.watch(localSessionReaderProvider);

  try {
    // Try server first - explicitly request archived sessions
    final serverSessions = await service.getSessions(includeArchived: true);
    debugPrint('[ChatProviders] Loaded ${serverSessions.length} archived sessions from server');
    return serverSessions;
  } catch (e) {
    debugPrint('[ChatProviders] Server unavailable, falling back to local sessions: $e');

    // Fall back to local sessions
    try {
      final localSessions = await localReader.getLocalSessions();
      debugPrint('[ChatProviders] Loaded ${localSessions.length} local sessions');
      return localSessions.where((s) => s.archived).toList();
    } catch (localError) {
      debugPrint('[ChatProviders] Error loading local sessions: $localError');
      return [];
    }
  }
});

/// Provider for the current session ID
///
/// When null, indicates a new chat should be started.
/// When set, the chat screen shows that session's messages.
final currentSessionIdProvider = StateProvider<String?>((ref) => null);

/// Provider for fetching a specific session with messages
final sessionWithMessagesProvider =
    FutureProvider.family<ChatSessionWithMessages?, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getSession(sessionId);
  } catch (e) {
    debugPrint('[ChatProviders] Error fetching session $sessionId: $e');
    return null;
  }
});


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
    );
  }
}

/// Information about a session that couldn't be resumed
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

/// Notifier for managing chat messages and streaming
class ChatMessagesNotifier extends StateNotifier<ChatMessagesState> {
  final ChatService _service;
  final Ref _ref;
  static const _uuid = Uuid();
  final _log = logger.createLogger('ChatMessagesNotifier');

  /// Track the session ID of the currently active stream
  /// Used to prevent old streams from updating state after session switch
  String? _activeStreamSessionId;

  /// Throttle for UI updates during streaming (50ms = ~20 updates/sec max)
  final _streamingThrottle = Throttle(const Duration(milliseconds: 50));

  /// Track pending content updates for batching
  List<MessageContent>? _pendingContent;

  /// Background stream manager for handling streams that survive navigation
  final BackgroundStreamManager _streamManager = BackgroundStreamManager.instance;

  /// Current stream subscription (for cleanup when navigating away)
  StreamSubscription<StreamEvent>? _currentStreamSubscription;

  ChatMessagesNotifier(this._service, this._ref) : super(const ChatMessagesState());

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
    // Cancel subscription to current stream
    _currentStreamSubscription?.cancel();
    _currentStreamSubscription = null;
    _activeStreamSessionId = null;

    // Cancel any polling timer
    _pollTimer?.cancel();
    _pollTimer = null;

    // Check if the new session has an active background stream
    final hasActiveStream = _streamManager.hasActiveStream(newSessionId);

    // Clear messages immediately and show loading state
    state = ChatMessagesState(
      sessionId: newSessionId,
      isLoading: true,
      isStreaming: hasActiveStream,
      // Clear all other fields to prevent showing stale content
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
    final trace = perf.trace('LoadSession', metadata: {'sessionId': sessionId});

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
        final sessionData = await _service.getSession(sessionId);
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
  /// session to get the final content.
  void _startPollingForStreamCompletion(String sessionId) {
    debugPrint('[ChatMessagesNotifier] >>> Starting polling for session: $sessionId');
    _pollTimer?.cancel();

    // Poll every 2 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      debugPrint('[ChatMessagesNotifier] >>> Poll tick for session: $sessionId');
      // Stop if we switched sessions
      if (state.sessionId != sessionId) {
        timer.cancel();
        _pollTimer = null;
        return;
      }

      try {
        final stillActive = await _service.hasActiveStream(sessionId);
        debugPrint('[ChatMessagesNotifier] Polling stream status for $sessionId: active=$stillActive');

        if (!stillActive) {
          // Stream completed - reload session to get final content
          timer.cancel();
          _pollTimer = null;
          debugPrint('[ChatMessagesNotifier] Server stream completed - reloading session');
          state = state.copyWith(isStreaming: false);
          await loadSession(sessionId);
          _ref.invalidate(chatSessionsProvider);
        } else {
          // Still streaming - reload to get latest content
          // This gives incremental updates while waiting
          final transcript = await _service.getSessionTranscript(sessionId);
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
          _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        }
        break;

      case StreamEventType.toolUse:
        // Tool call event
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
              _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
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
          _updateOrAddAssistantMessage(_reattachStreamContent, sessionId, isStreaming: true);
        }
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

      case StreamEventType.init:
      case StreamEventType.sessionUnavailable:
      case StreamEventType.userQuestion:
        // userQuestion events are handled separately via pendingUserQuestion state
        // The UI should listen for these and display the UserQuestionCard
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

    // Check if the last message is an assistant message that's streaming
    if (messages.isNotEmpty &&
        messages.last.role == MessageRole.assistant) {
      // Update existing assistant message
      messages[messages.length - 1] = messages.last.copyWith(
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
    _currentStreamSubscription?.cancel();
    _currentStreamSubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  /// Clear current session (for new chat)
  ///
  /// Also cancels any active stream by invalidating the stream session ID.
  /// Preserves workingDirectory if [preserveWorkingDirectory] is true.
  /// Note: Background streams continue even when session is cleared.
  void clearSession({bool preserveWorkingDirectory = false}) {
    // Cancel subscription but let background stream continue
    _currentStreamSubscription?.cancel();
    _currentStreamSubscription = null;
    _activeStreamSessionId = null;

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
  }) async {
    if (state.isStreaming) return;

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
    );

    // Track accumulated content for streaming
    List<MessageContent> accumulatedContent = [];
    String? actualSessionId;

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

      await for (final event in _service.streamChat(
        sessionId: existingSessionId,  // null for new sessions, real ID for existing
        message: message,
        systemPrompt: systemPrompt,
        initialContext: initialContext,
        priorConversation: effectivePriorConversation,
        continuedFrom: continuedFromId,
        workingDirectory: state.workingDirectory,
        contexts: effectiveContexts,
        attachments: attachments,
      )) {
        // Check if session has changed (user switched chats during stream)
        // Don't break the stream - let it continue in background so server keeps processing
        // Just skip UI updates for this session
        final isBackgroundStream = _activeStreamSessionId != displaySessionId;
        if (isBackgroundStream) {
          // Only process terminal events (done/error) when in background
          // This keeps the HTTP connection alive so server continues processing
          if (event.type != StreamEventType.done &&
              event.type != StreamEventType.error &&
              event.type != StreamEventType.aborted) {
            continue; // Skip UI updates but keep consuming stream
          }
        }

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
              actualSessionId = eventSessionId;
              if (eventSessionId != displaySessionId) {
                // Update session ID if server assigned a different one (always true for new sessions)
                debugPrint('[ChatMessagesNotifier] Session event has server ID: $actualSessionId (was: $displaySessionId)');
                _ref.read(currentSessionIdProvider.notifier).state = actualSessionId;
                // ALSO update state.sessionId so future sendMessage calls use the correct ID
                state = state.copyWith(sessionId: actualSessionId);
                // Update the active stream ID to match the real session ID
                _activeStreamSessionId = actualSessionId;
                // CRITICAL: Also update displaySessionId so the background stream check works correctly
                // Without this, subsequent events would be treated as background stream events and skipped
                displaySessionId = actualSessionId;
              }
              // Refresh sessions list now that we have a valid session ID
              // (The session should now exist in the server's database)
              _ref.invalidate(chatSessionsProvider);
            } else {
              debugPrint('[ChatMessagesNotifier] Session event has no valid session ID (new session) - will get ID from done event');
              // Don't refresh session list yet - session not created on server
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
              final hasTextContent = accumulatedContent.any((c) => c.type == ContentType.text);
              if (hasTextContent) {
                // Replace the last text content
                final lastTextIndex = accumulatedContent.lastIndexWhere(
                    (c) => c.type == ContentType.text);
                accumulatedContent[lastTextIndex] = MessageContent.text(content);
              } else {
                accumulatedContent.add(MessageContent.text(content));
              }
              _updateAssistantMessage(accumulatedContent, isStreaming: true);
            }
            break;

          case StreamEventType.toolUse:
            // Flush any pending UI updates before showing tool call
            _flushPendingUpdates();

            // Tool call event - convert any pending text to "thinking"
            final toolCall = event.toolCall;
            if (toolCall != null) {
              // Check if there's text content before this tool call
              final lastTextIndex = accumulatedContent.lastIndexWhere(
                  (c) => c.type == ContentType.text);
              if (lastTextIndex >= 0) {
                // Convert the last text block to thinking
                final thinkingText = accumulatedContent[lastTextIndex].text ?? '';
                if (thinkingText.isNotEmpty) {
                  accumulatedContent[lastTextIndex] = MessageContent.thinking(thinkingText);
                }
              }
              accumulatedContent.add(MessageContent.toolUse(toolCall));
              // Force immediate update for tool events (not throttled)
              _performMessageUpdate(accumulatedContent, isStreaming: true);
            }
            break;

          case StreamEventType.toolResult:
            // Tool result - attach to the corresponding tool call
            final toolUseId = event.toolUseId;
            final resultContent = event.toolResultContent;
            if (toolUseId != null && resultContent != null) {
              // Find the tool call with this ID and update it with the result
              for (int i = 0; i < accumulatedContent.length; i++) {
                final content = accumulatedContent[i];
                if (content.type == ContentType.toolUse &&
                    content.toolCall?.id == toolUseId) {
                  // Replace with updated tool call that has the result
                  final updatedToolCall = content.toolCall!.withResult(
                    resultContent,
                    isError: event.toolResultIsError,
                  );
                  accumulatedContent[i] = MessageContent.toolUse(updatedToolCall);
                  _updateAssistantMessage(accumulatedContent, isStreaming: true);
                  break;
                }
              }
            }
            break;

          case StreamEventType.done:
            // Stream complete - handle differently for background vs foreground
            debugPrint('[ChatMessagesNotifier] Done event received (background: $isBackgroundStream, sessionId: $displaySessionId)');

            if (!isBackgroundStream) {
              // Foreground: update UI normally
              _updateAssistantMessage(accumulatedContent, isStreaming: false);

              // CRITICAL: Capture session ID from done event (for new sessions, this is the first time we get the real ID)
              final doneSessionId = event.sessionId;
              // Validate session ID - reject "pending" or empty values
              final isValidSessionId = doneSessionId != null &&
                  doneSessionId.isNotEmpty &&
                  doneSessionId != 'pending';

              if (isValidSessionId && doneSessionId != actualSessionId) {
                debugPrint('[ChatMessagesNotifier] Done event has new session ID: $doneSessionId (was: $actualSessionId)');
                actualSessionId = doneSessionId;
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
            } else {
              // Background: stream completed while user was on another session
              debugPrint('[ChatMessagesNotifier] Background stream completed for session: $displaySessionId');
            }
            // Always refresh sessions list to get updated title
            _ref.invalidate(chatSessionsProvider);
            // Search indexing is handled by the agent server via MCP
            break;

          case StreamEventType.error:
            final errorMsg = event.errorMessage ?? 'Unknown error';
            if (!isBackgroundStream) {
              // Foreground: show error to user
              state = state.copyWith(
                isStreaming: false,
                error: errorMsg,
              );
              // Append error to existing content instead of replacing everything
              // This preserves thinking/tool progress that was shown before the error
              accumulatedContent.add(MessageContent.text('\n\n⚠️ Error: $errorMsg'));
              _updateAssistantMessage(accumulatedContent, isStreaming: false);
            } else {
              // Background: just log it
              debugPrint('[ChatMessagesNotifier] Background stream error for session $displaySessionId: $errorMsg');
            }
            break;

          case StreamEventType.thinking:
            // Extended thinking content from Claude
            final thinkingText = event.thinkingContent;
            if (thinkingText != null && thinkingText.isNotEmpty) {
              accumulatedContent.add(MessageContent.thinking(thinkingText));
              _updateAssistantMessage(accumulatedContent, isStreaming: true);
            }
            break;

          case StreamEventType.sessionUnavailable:
            // SDK session couldn't be resumed - ask user how to proceed
            debugPrint('[ChatMessagesNotifier] Session unavailable (background: $isBackgroundStream)');
            if (!isBackgroundStream) {
              final unavailableInfo = SessionUnavailableInfo(
                sessionId: event.sessionId ?? actualSessionId ?? '',
                reason: event.unavailableReason ?? 'unknown',
                hasMarkdownHistory: event.hasMarkdownHistory,
                messageCount: event.markdownMessageCount,
                message: event.unavailableMessage ?? 'Session could not be resumed.',
                pendingMessage: message,
              );
              state = state.copyWith(
                isStreaming: false,
                sessionUnavailable: unavailableInfo,
              );
              debugPrint('[ChatMessagesNotifier] Session unavailable: ${unavailableInfo.reason}');
            }
            return; // Stop processing, wait for user decision

          case StreamEventType.aborted:
            // Stream was stopped by user - session is still valid for future messages
            debugPrint('[ChatMessagesNotifier] Stream aborted (background: $isBackgroundStream, sessionId: $displaySessionId)');
            if (!isBackgroundStream) {
              _updateAssistantMessage(accumulatedContent, isStreaming: false);
              state = state.copyWith(isStreaming: false);
              // Reload session to get the final state (use actual ID if we have it)
              if (actualSessionId != null) {
                loadSession(actualSessionId);
              }
            }
            return; // Exit the stream loop

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

      // If we exited the loop without a done/error event (e.g., unexpected stream end),
      // make sure to stop streaming state so the user can send another message
      // But only if this is still the active session
      if (state.isStreaming && _activeStreamSessionId == displaySessionId) {
        debugPrint('[ChatMessagesNotifier] Stream ended without done event - cleaning up');
        state = state.copyWith(isStreaming: false);
      }
    } catch (e) {
      debugPrint('[ChatMessagesNotifier] Stream error: $e');
      // Only update UI if this is still the active session
      if (_activeStreamSessionId == displaySessionId) {
        state = state.copyWith(
          isStreaming: false,
          error: e.toString(),
        );
        // Append error to existing content instead of replacing everything
        // This preserves thinking/tool progress that was shown before the error
        accumulatedContent.add(MessageContent.text('\n\n⚠️ Error: $e'));
        _updateAssistantMessage(accumulatedContent, isStreaming: false);
      }
    } finally {
      // Final safety net: ensure streaming is always stopped when sendMessage exits
      if (state.isStreaming && _activeStreamSessionId == displaySessionId) {
        debugPrint('[ChatMessagesNotifier] Finally block cleanup - forcing streaming off');
        state = state.copyWith(isStreaming: false);
      }
    }
  }

  /// Update the assistant message being streamed
  /// Uses throttling during streaming to reduce UI updates
  void _updateAssistantMessage(List<MessageContent> content, {required bool isStreaming}) {
    // Always update immediately when streaming ends
    if (!isStreaming) {
      _pendingContent = null;
      _performMessageUpdate(content, isStreaming: false);
      _streamingThrottle.reset();
      return;
    }

    // Store pending content
    _pendingContent = content;

    // Throttle UI updates during streaming
    if (_streamingThrottle.shouldProceed()) {
      _performMessageUpdate(content, isStreaming: true);
    }
  }

  /// Actually perform the message update (called from throttled path)
  void _performMessageUpdate(List<MessageContent> content, {required bool isStreaming}) {
    final trace = perf.trace('MessageUpdate', metadata: {
      'messageCount': state.messages.length,
      'contentBlocks': content.length,
    });

    final messages = List<ChatMessage>.from(state.messages);
    if (messages.isEmpty) {
      trace.end();
      return;
    }

    // Find the last assistant message (should be the streaming one)
    final lastIndex = messages.length - 1;
    if (messages[lastIndex].role != MessageRole.assistant) {
      trace.end();
      return;
    }

    messages[lastIndex] = messages[lastIndex].copyWith(
      content: List.from(content),
      isStreaming: isStreaming,
    );

    state = state.copyWith(messages: messages);
    trace.end();
  }

  /// Flush any pending content updates (call when important events happen)
  void _flushPendingUpdates() {
    if (_pendingContent != null) {
      _performMessageUpdate(_pendingContent!, isStreaming: true);
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
        debugPrint('[ChatMessagesNotifier] Failed to submit answer');
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
  final notifier = ChatMessagesNotifier(service, ref);

  // Ensure proper cleanup when provider is disposed
  ref.onDispose(() {
    notifier.dispose();
  });

  return notifier;
});

// ============================================================
// Session Management Actions
// ============================================================

/// Provider for deleting a session
final deleteSessionProvider = Provider<Future<void> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return (String sessionId) async {
    await service.deleteSession(sessionId);
    // Clear current session if it was deleted
    if (ref.read(currentSessionIdProvider) == sessionId) {
      ref.read(currentSessionIdProvider.notifier).state = null;
      ref.read(chatMessagesProvider.notifier).clearSession();
    }
    // Refresh sessions list
    ref.invalidate(chatSessionsProvider);
    ref.invalidate(archivedSessionsProvider);
  };
});

/// Provider for archiving a session
final archiveSessionProvider = Provider<Future<void> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return (String sessionId) async {
    await service.archiveSession(sessionId);
    // Defer invalidation to next frame to avoid _dependents.isEmpty assertion
    // This can happen if the widget watching these providers is being disposed
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(chatSessionsProvider);
      ref.invalidate(archivedSessionsProvider);
    });
  };
});

/// Provider for unarchiving a session
final unarchiveSessionProvider = Provider<Future<void> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return (String sessionId) async {
    await service.unarchiveSession(sessionId);
    // Defer invalidation to next frame to avoid _dependents.isEmpty assertion
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(chatSessionsProvider);
      ref.invalidate(archivedSessionsProvider);
    });
  };
});

/// Provider for creating a new chat
final newChatProvider = Provider<void Function()>((ref) {
  return () {
    ref.read(currentSessionIdProvider.notifier).state = null;
    ref.read(chatMessagesProvider.notifier).clearSession();
  };
});

/// Provider for switching to a session
///
/// All sessions are loaded from the server API.
final switchSessionProvider = Provider<Future<void> Function(String)>((ref) {
  return (String sessionId) async {
    // Immediately clear old messages and show loading state to prevent
    // showing stale content from previous session during async load
    ref.read(chatMessagesProvider.notifier).prepareForSessionSwitch(sessionId);
    ref.read(currentSessionIdProvider.notifier).state = sessionId;
    await ref.read(chatMessagesProvider.notifier).loadSession(sessionId);
  };
});

/// Provider for continuing an imported session
///
/// Creates a new chat that continues from the given session,
/// passing all prior messages as context for the AI.
final continueSessionProvider = Provider<Future<void> Function(ChatSession)>((ref) {
  final service = ref.watch(chatServiceProvider);

  return (ChatSession originalSession) async {
    debugPrint('[ChatProviders] continueSessionProvider called');
    debugPrint('[ChatProviders] Original session ID: ${originalSession.id}');

    try {
      // Load prior messages from server
      debugPrint('[ChatProviders] Loading messages from server...');
      final sessionData = await service.getSession(originalSession.id);
      final priorMessages = sessionData?.messages ?? [];
      debugPrint('[ChatProviders] Loaded ${priorMessages.length} messages from server');

      // Clear current session and set up continuation
      ref.read(currentSessionIdProvider.notifier).state = null;
      ref.read(chatMessagesProvider.notifier).setupContinuation(
        originalSession: originalSession,
        priorMessages: priorMessages,
      );
    } catch (e, st) {
      debugPrint('[ChatProviders] Error setting up continuation: $e');
      debugPrint('[ChatProviders] Stack trace: $st');
      // Fall back to just clearing the session
      ref.read(currentSessionIdProvider.notifier).state = null;
      ref.read(chatMessagesProvider.notifier).clearSession();
    }
  };
});

// ============================================================
// Vault Browsing
// ============================================================

/// Provider for browsing vault directories
///
/// Use with .family to specify the path:
/// - ref.watch(vaultDirectoryProvider('')) - vault root
/// - ref.watch(vaultDirectoryProvider('Projects')) - Projects folder
/// - ref.watch(vaultDirectoryProvider('Projects/myapp')) - specific project
final vaultDirectoryProvider = FutureProvider.family<List<VaultEntry>, String>((ref, path) async {
  final service = ref.watch(chatServiceProvider);
  return service.listDirectory(path: path);
});

/// Provider for the current working directory path being browsed
final currentBrowsePathProvider = StateProvider<String>((ref) => '');

/// Provider for the selected working directory for new chats
///
/// This is the working directory that will be used when starting a new chat.
/// null means use the default (Chat/).
final selectedWorkingDirectoryProvider = StateProvider<String?>((ref) => null);

// ============================================================
// Context Selection
// ============================================================

/// Provider for available context files
///
/// Fetches context files from Chat/contexts/ directory.
/// Returns empty list if server is unavailable (graceful degradation).
final availableContextsProvider = FutureProvider<List<ContextFile>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getContexts();
  } catch (e) {
    debugPrint('[ChatProviders] Error loading contexts: $e');
    return []; // Graceful degradation - show no contexts if server unavailable
  }
});

/// Provider for selected context file paths for new chats
///
/// Default: empty list (no pre-selected contexts)
/// Paths are relative to vault (e.g., "Chat/contexts/work-context.md")
/// Users can select contexts from the new chat sheet before starting.
final selectedContextsProvider = StateProvider<List<String>>((ref) {
  return []; // Start with no contexts - user can select from available files
});

// ============================================================
// Context Folders (CLAUDE.md hierarchy)
// ============================================================

/// Provider for available context folders
///
/// Fetches folders with CLAUDE.md files that can be
/// selected as context for a session.
final contextFoldersProvider = FutureProvider<List<ContextFolder>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getContextFolders();
  } catch (e) {
    debugPrint('[ChatProviders] Error loading context folders: $e');
    return []; // Graceful degradation
  }
});

/// Provider for selected context folder paths for new chats
///
/// Default: [""] to include root CLAUDE.md (Parachute context)
/// Paths are folder paths relative to vault (e.g., "Projects/parachute")
final selectedContextFoldersProvider = StateProvider<List<String>>((ref) {
  return [""]; // Default to root CLAUDE.md (Parachute context)
});

/// Provider to get context chain for selected folders
///
/// Shows all CLAUDE.md files that will be loaded, including parent chain.
/// Pass folder paths as comma-separated string (e.g., ",Projects/parachute")
/// Empty string "" represents root folder.
final contextChainProvider =
    FutureProvider.family<ContextChain, String>((ref, foldersParam) async {
  final service = ref.watch(chatServiceProvider);
  try {
    if (foldersParam.isEmpty) {
      return const ContextChain(files: [], totalTokens: 0);
    }
    // Split comma-separated string back to list
    final folderPaths = foldersParam.split(',');
    return await service.getContextChain(folderPaths);
  } catch (e) {
    debugPrint('[ChatProviders] Error loading context chain: $e');
    return const ContextChain(files: [], totalTokens: 0);
  }
});

/// Provider for current session's context folders
///
/// Fetches the context folders configured for the current session.
final sessionContextFoldersProvider =
    FutureProvider.family<List<String>, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  return await service.getSessionContextFolders(sessionId);
});

// ============================================================
// Curator Session
// ============================================================

/// Provider for curator info for a specific session
///
/// Fetches curator session data and recent task history.
/// Use with .family to specify the session ID:
/// - ref.watch(curatorInfoProvider(sessionId))
final curatorInfoProvider = FutureProvider.family<CuratorInfo, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  return service.getCuratorInfo(sessionId);
});

/// Provider for curator conversation messages
///
/// Fetches the curator's full conversation history showing what
/// context it was fed and how it made decisions.
/// The curator is a persistent SDK session, so we can view its transcript.
/// Use with .family to specify the session ID:
/// - ref.watch(curatorMessagesProvider(sessionId))
final curatorMessagesProvider = FutureProvider.family<CuratorMessages, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  return service.getCuratorMessages(sessionId);
});

/// Provider for manually triggering a curator run
///
/// Returns a function that triggers the curator for a session.
/// Usage: await ref.read(triggerCuratorProvider)(sessionId);
final triggerCuratorProvider = Provider<Future<int> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return (String sessionId) async {
    final taskId = await service.triggerCurator(sessionId);
    // Invalidate the curator info to refresh the task list
    ref.invalidate(curatorInfoProvider(sessionId));
    // Also refresh sessions list in case title was updated
    ref.invalidate(chatSessionsProvider);
    return taskId;
  };
});

// ============================================================
// Curator Activity Providers
// ============================================================

/// Provider for recent curator activity across all sessions
///
/// Fetches recent context file updates and title changes.
/// Auto-refreshes every 30 seconds when watched.
final curatorActivityProvider = FutureProvider<CuratorActivityInfo>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getRecentCuratorActivity(limit: 10);
  } catch (e) {
    debugPrint('[ChatProviders] Error fetching curator activity: $e');
    // Return empty activity on error
    return const CuratorActivityInfo(
      recentUpdates: [],
      contextFilesModified: [],
    );
  }
});

/// Provider for context files metadata
///
/// Returns structured info about each context file including
/// fact counts, history entries, and last modified time.
final contextFilesInfoProvider = FutureProvider<ContextFilesInfo>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getContextFilesInfo();
  } catch (e) {
    debugPrint('[ChatProviders] Error fetching context files info: $e');
    return const ContextFilesInfo(
      files: [],
      totalFacts: 0,
      totalHistoryEntries: 0,
    );
  }
});
