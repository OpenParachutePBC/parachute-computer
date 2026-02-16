import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../models/chat_message.dart';
import '../models/claude_usage.dart';
import '../services/chat_service.dart';
import '../services/local_session_reader.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/services/file_system_service.dart';

// ============================================================
// Service Providers
// ============================================================

/// Provider for ChatService
///
/// Creates a new ChatService instance with the configured server URL and API key.
/// The service handles all communication with the parachute-agent backend.
final chatServiceProvider = Provider<ChatService>((ref) {
  // Import these from app_state_provider
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';

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

// ============================================================
// Session List Providers
// ============================================================

/// Provider for fetching all chat sessions (non-archived only)
///
/// Tries to fetch from the server first. If server is unavailable,
/// falls back to reading local session files from the vault.
final chatSessionsProvider = FutureProvider.autoDispose<List<ChatSession>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  final localReader = ref.watch(localSessionReaderProvider);

  try {
    // Try server first - gets non-archived sessions by default
    final serverSessions = await service.getSessions();
    debugPrint('[ChatProviders] Loaded ${serverSessions.length} sessions from server');
    // Sort: pending approval first, then by updatedAt descending
    serverSessions.sort((a, b) {
      if (a.isPendingApproval && !b.isPendingApproval) return -1;
      if (!a.isPendingApproval && b.isPendingApproval) return 1;
      final aTime = a.updatedAt ?? a.createdAt;
      final bTime = b.updatedAt ?? b.createdAt;
      return bTime.compareTo(aTime);
    });
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
final archivedSessionsProvider = FutureProvider.autoDispose<List<ChatSession>>((ref) async {
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

// ============================================================
// Current Session State
// ============================================================

/// Provider for the current active session ID
///
/// null means no session is active (new chat mode)
final currentSessionIdProvider = StateProvider<String?>((ref) => null);

/// Provider for session with full message history
///
/// Returns the complete session data including all messages.
/// Used for displaying imported sessions and session details.
final sessionWithMessagesProvider =
    FutureProvider.autoDispose.family<ChatSessionWithMessages?, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  return await service.getSession(sessionId);
});

// ============================================================
// Pending Pairing Count (Polling)
// ============================================================

/// Polls for pending pairing request count every 30 seconds.
/// Returns 0 if server is unreachable. Auto-disposes when no widget watches it.
final pendingPairingCountProvider = StreamProvider.autoDispose<int>((ref) {
  final service = ref.watch(chatServiceProvider);

  late final StreamController<int> controller;
  Timer? timer;

  controller = StreamController<int>(
    onListen: () async {
      // Initial fetch
      try {
        final count = await service.getPendingPairingCount();
        if (!controller.isClosed) controller.add(count);
      } catch (_) {
        if (!controller.isClosed) controller.add(0);
      }

      // Periodic polling
      timer = Timer.periodic(const Duration(seconds: 30), (_) async {
        try {
          final count = await service.getPendingPairingCount();
          if (!controller.isClosed) controller.add(count);
        } catch (_) {
          if (!controller.isClosed) controller.add(0);
        }
      });
    },
  );

  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});

// Session CRUD and navigation actions are in chat_session_actions.dart
// to avoid circular dependency with chat_message_providers.dart

/// Provider for current session's context folders
///
/// Fetches the context folders configured for the current session.
final sessionContextFoldersProvider =
    FutureProvider.autoDispose.family<List<String>, String>((ref, sessionId) async {
  final service = ref.watch(chatServiceProvider);
  return await service.getSessionContextFolders(sessionId);
});

/// Provider for Claude usage limits
///
/// Fetches current usage data from the server (which reads from Claude Code's OAuth).
/// Refreshes automatically every 2 minutes when the provider is being watched.
final claudeUsageProvider = FutureProvider.autoDispose<ClaudeUsage>((ref) async {
  final service = ref.watch(chatServiceProvider);

  try {
    final usage = await service.getUsage();
    return usage;
  } catch (e) {
    debugPrint('[ChatProviders] Error fetching Claude usage: $e');
    return ClaudeUsage(error: e.toString());
  }
});
