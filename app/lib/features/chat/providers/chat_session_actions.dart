import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';
import 'chat_message_providers.dart';

// ============================================================
// Session CRUD Actions
// ============================================================
//
// These providers are in a separate file to avoid circular dependency:
// - chat_session_providers.dart defines chatServiceProvider and session list providers
// - chat_message_providers.dart defines chatMessagesProvider
// - This file uses both, so it must import both
//
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

// ============================================================
// Session Navigation
// ============================================================

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
