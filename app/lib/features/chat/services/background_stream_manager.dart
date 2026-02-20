import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/stream_event.dart';

/// Callback for stream events
typedef StreamEventCallback = void Function(StreamEvent event);

/// Manages background streams that survive navigation
///
/// This ensures that if a user navigates away while Claude is responding,
/// the stream continues to completion. The server continues processing
/// and saves the session, so when the user returns they see the complete
/// response.
///
/// Key behaviors:
/// - Streams run to completion even after navigation
/// - Multiple streams can run concurrently (different sessions)
/// - Provides callback interface for UI updates when active
/// - Tracks which sessions have active streams
/// - Enforces a max concurrent stream limit to prevent resource exhaustion
///
/// Use via Riverpod provider (backgroundStreamManagerProvider) in widget code.
class BackgroundStreamManager {
  BackgroundStreamManager.internal();

  /// Maximum number of concurrent background streams.
  /// When exceeded, the oldest stream is evicted (cancelled).
  static const int maxConcurrentStreams = 5;

  /// Active streams by session ID
  final Map<String, _ActiveStream> _activeStreams = {};

  /// Check if a session has an active stream
  bool hasActiveStream(String sessionId) {
    return _activeStreams.containsKey(sessionId);
  }

  /// Get all sessions with active streams
  Set<String> get activeSessionIds => _activeStreams.keys.toSet();

  /// Register a stream for background processing
  ///
  /// The stream will run to completion regardless of navigation.
  /// [onEvent] is called for each event while the callback is registered.
  /// Returns a subscription that can be used to unregister the callback.
  ///
  /// If the concurrent stream limit is exceeded, the oldest stream is
  /// evicted (cancelled) to make room.
  StreamSubscription<StreamEvent> registerStream({
    required String sessionId,
    required Stream<StreamEvent> stream,
    required StreamEventCallback onEvent,
    VoidCallback? onDone,
    Function(Object error)? onError,
  }) {
    // If there's already an active stream for this session, cancel it
    _activeStreams[sessionId]?.cancel();
    _activeStreams.remove(sessionId);

    // Enforce stream limit — evict the oldest stream if at capacity
    _evictIfNeeded();

    debugPrint('[BackgroundStreamManager] Registering stream for session: $sessionId '
        '(active: ${_activeStreams.length + 1}/$maxConcurrentStreams)');

    // Create a broadcast stream so multiple listeners can subscribe
    final controller = StreamController<StreamEvent>.broadcast();

    final activeStream = _ActiveStream(
      sessionId: sessionId,
      controller: controller,
    );
    _activeStreams[sessionId] = activeStream;

    // Consume the source stream and forward to broadcast
    _consumeStream(activeStream, stream);

    // Return a subscription that updates UI
    return controller.stream.listen(
      onEvent,
      onDone: onDone,
      onError: onError != null ? (e, _) => onError(e) : null,
    );
  }

  /// Evict the oldest stream if at or above the concurrent limit.
  void _evictIfNeeded() {
    while (_activeStreams.length >= maxConcurrentStreams) {
      // Dart LinkedHashMap preserves insertion order — first key is oldest
      final oldestId = _activeStreams.keys.first;
      debugPrint('[BackgroundStreamManager] Evicting oldest stream: $oldestId '
          '(limit: $maxConcurrentStreams)');
      _activeStreams[oldestId]?.cancel();
      _activeStreams.remove(oldestId);
    }
  }

  /// Consume a stream and forward events to the broadcast controller.
  ///
  /// Uses a manual [StreamSubscription] so it can be cancelled explicitly
  /// on eviction (closing the underlying HTTP connection).
  void _consumeStream(
    _ActiveStream activeStream,
    Stream<StreamEvent> source,
  ) {
    final controller = activeStream.controller;

    void cleanup() {
      // Use activeStream.sessionId which tracks the current ID even after
      // updateSessionId() remaps "pending" → real ID.
      final currentId = activeStream.sessionId;
      debugPrint('[BackgroundStreamManager] Stream completed for session: $currentId');
      _activeStreams.remove(currentId);
      if (!controller.isClosed) {
        controller.close();
      }
    }

    activeStream.sourceSubscription = source.listen(
      (event) {
        // Stop consuming if the controller was closed externally (eviction)
        if (controller.isClosed) {
          debugPrint('[BackgroundStreamManager] Controller closed (evicted?) for ${activeStream.sessionId} — stopping consumption');
          activeStream.sourceSubscription?.cancel();
          return;
        }

        controller.add(event);

        // Check for terminal events
        if (event.type == StreamEventType.done ||
            event.type == StreamEventType.error ||
            event.type == StreamEventType.typedError ||
            event.type == StreamEventType.aborted) {
          activeStream.sourceSubscription?.cancel();
          cleanup();
        }
      },
      onError: (Object e) {
        debugPrint('[BackgroundStreamManager] Stream error for ${activeStream.sessionId}: $e');
        if (!controller.isClosed) {
          controller.addError(e);
        }
        cleanup();
      },
      onDone: cleanup,
    );
  }

  /// Update the session ID for an active stream
  ///
  /// Called when the server assigns a real session ID to replace a temporary
  /// one (e.g., "pending" → actual SDK session ID). This ensures that
  /// reattach and hasActiveStream work with the real ID.
  void updateSessionId(String oldId, String newId) {
    final activeStream = _activeStreams.remove(oldId);
    if (activeStream != null) {
      debugPrint('[BackgroundStreamManager] Updating session ID: $oldId → $newId');
      activeStream.sessionId = newId;
      _activeStreams[newId] = activeStream;
    }
  }

  /// Update the callback for an active stream
  ///
  /// Call this when navigating back to a session that has an active stream.
  /// Returns a subscription, or null if no active stream exists.
  StreamSubscription<StreamEvent>? reattachCallback({
    required String sessionId,
    required StreamEventCallback onEvent,
    VoidCallback? onDone,
    Function(Object error)? onError,
  }) {
    final activeStream = _activeStreams[sessionId];
    if (activeStream == null) {
      debugPrint('[BackgroundStreamManager] No active stream for session: $sessionId');
      return null;
    }

    debugPrint('[BackgroundStreamManager] Reattaching callback for session: $sessionId');

    // Subscribe to the broadcast controller
    return activeStream.controller.stream.listen(
      onEvent,
      onDone: onDone,
      onError: onError != null ? (e, _) => onError(e) : null,
    );
  }

  /// Cancel a stream for a session
  void cancelStream(String sessionId) {
    final activeStream = _activeStreams[sessionId];
    if (activeStream != null) {
      debugPrint('[BackgroundStreamManager] Cancelling stream for session: $sessionId');
      activeStream.cancel();
      _activeStreams.remove(sessionId);
    }
  }

  /// Cancel all active streams
  void cancelAll() {
    debugPrint('[BackgroundStreamManager] Cancelling all streams');
    for (final stream in _activeStreams.values) {
      stream.cancel();
    }
    _activeStreams.clear();
  }
}

/// Internal class to track an active stream
class _ActiveStream {
  /// Mutable — updated by [BackgroundStreamManager.updateSessionId] when the
  /// server assigns a real ID to replace "pending".
  String sessionId;
  final StreamController<StreamEvent> controller;

  /// Subscription to the source HTTP stream. Set after [_consumeStream] starts.
  /// Cancelled explicitly on eviction to close the underlying HTTP connection.
  StreamSubscription<StreamEvent>? sourceSubscription;

  _ActiveStream({
    required this.sessionId,
    required this.controller,
  });

  void cancel() {
    sourceSubscription?.cancel();
    if (!controller.isClosed) {
      controller.close();
    }
  }
}
