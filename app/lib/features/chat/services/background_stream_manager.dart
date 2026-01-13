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
class BackgroundStreamManager {
  static final BackgroundStreamManager _instance = BackgroundStreamManager._();
  static BackgroundStreamManager get instance => _instance;

  BackgroundStreamManager._();

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
  StreamSubscription<StreamEvent> registerStream({
    required String sessionId,
    required Stream<StreamEvent> stream,
    required StreamEventCallback onEvent,
    VoidCallback? onDone,
    Function(Object error)? onError,
  }) {
    // If there's already an active stream for this session, cancel it
    _activeStreams[sessionId]?.cancel();

    debugPrint('[BackgroundStreamManager] Registering stream for session: $sessionId');

    // Create a broadcast stream so multiple listeners can subscribe
    final controller = StreamController<StreamEvent>.broadcast();

    final activeStream = _ActiveStream(
      sessionId: sessionId,
      controller: controller,
      onEvent: onEvent,
    );
    _activeStreams[sessionId] = activeStream;

    // Consume the source stream and forward to broadcast
    _consumeStream(sessionId, stream, controller, onDone, onError);

    // Return a subscription that updates UI
    return controller.stream.listen(
      onEvent,
      onDone: onDone,
      onError: onError != null ? (e, _) => onError(e) : null,
    );
  }

  /// Consume a stream and forward events to the controller
  Future<void> _consumeStream(
    String sessionId,
    Stream<StreamEvent> source,
    StreamController<StreamEvent> controller,
    VoidCallback? onDone,
    Function(Object error)? onError,
  ) async {
    try {
      await for (final event in source) {
        if (!controller.isClosed) {
          controller.add(event);
        }

        // Check for terminal events
        if (event.type == StreamEventType.done ||
            event.type == StreamEventType.error) {
          break;
        }
      }
    } catch (e) {
      debugPrint('[BackgroundStreamManager] Stream error for $sessionId: $e');
      if (!controller.isClosed) {
        controller.addError(e);
      }
    } finally {
      debugPrint('[BackgroundStreamManager] Stream completed for session: $sessionId');
      _activeStreams.remove(sessionId);
      if (!controller.isClosed) {
        await controller.close();
      }
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
  final String sessionId;
  final StreamController<StreamEvent> controller;
  StreamEventCallback onEvent;

  _ActiveStream({
    required this.sessionId,
    required this.controller,
    required this.onEvent,
  });

  void cancel() {
    if (!controller.isClosed) {
      controller.close();
    }
  }
}
