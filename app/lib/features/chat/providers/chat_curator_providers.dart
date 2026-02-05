import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/curator_session.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

// ============================================================
// Curator Session
// ============================================================

/// Provider for curator info for a specific session
///
/// Fetches curator session data and recent task history.
/// Use with .family to specify the session ID:
/// - ref.watch(curatorInfoProvider(sessionId))
final curatorInfoProvider = FutureProvider.autoDispose.family<CuratorInfo, String>((ref, sessionId) async {
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
final curatorMessagesProvider = FutureProvider.autoDispose.family<CuratorMessages, String>((ref, sessionId) async {
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
final curatorActivityProvider = FutureProvider.autoDispose<CuratorActivityInfo>((ref) async {
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
final contextFilesInfoProvider = FutureProvider.autoDispose<ContextFilesInfo>((ref) async {
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
