import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/curator_run.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Derives the curator last run for the current active session.
///
/// Returns null if no session is active, while loading, or if the curator
/// hasn't run yet. Re-evaluates after each session fetch (which happens
/// automatically after each stream completes).
final curatorLastRunProvider = Provider.autoDispose<CuratorRun?>((ref) {
  final sessionId = ref.watch(currentSessionIdProvider);
  if (sessionId == null) return null;

  // sessionWithMessagesProvider fetches the full session including metadata.
  // .valueOrNull is null while loading — chip stays hidden until data arrives.
  final sessionAsync = ref.watch(sessionWithMessagesProvider(sessionId));
  return sessionAsync.valueOrNull?.session.curatorLastRun;
});

/// Gets the curator's own SDK session ID for a given chat session.
///
/// The curator session is 1:1 with the chat session and accumulates full
/// conversational context across all cadence runs.
final curatorSessionIdProvider =
    Provider.autoDispose.family<String?, String>((ref, chatSessionId) {
  final sessionAsync = ref.watch(sessionWithMessagesProvider(chatSessionId));
  return sessionAsync.valueOrNull?.session.curatorSessionId;
});

/// Returns a function that triggers a manual curator run for a session.
final triggerCuratorProvider =
    Provider<Future<void> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return service.triggerCurator;
});

/// Fetches the curator's conversation transcript for a given chat session.
///
/// Messages are loaded from the dedicated curator/messages endpoint, which
/// reads the JSONL directly — the curator session is never in SQLite so it
/// won't appear in the chat list.
final curatorMessagesProvider =
    FutureProvider.autoDispose.family<List<CuratorMessage>, String>(
  (ref, chatSessionId) async {
    final service = ref.watch(chatServiceProvider);
    final rawMessages = await service.getCuratorMessages(chatSessionId);
    return rawMessages.map((m) => CuratorMessage.fromJson(m)).toList();
  },
);
