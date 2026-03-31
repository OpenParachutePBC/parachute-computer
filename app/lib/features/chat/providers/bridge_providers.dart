import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/bridge_run.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Derives the bridge agent last run for the current active session.
///
/// Returns null if no session is active, while loading, or if the bridge
/// hasn't run yet. Re-evaluates after each session fetch (which happens
/// automatically after each stream completes).
final bridgeLastRunProvider = Provider.autoDispose<BridgeRun?>((ref) {
  final sessionId = ref.watch(currentSessionIdProvider);
  if (sessionId == null) return null;

  // sessionWithMessagesProvider fetches the full session including metadata.
  // .valueOrNull is null while loading — chip stays hidden until data arrives.
  final sessionAsync = ref.watch(sessionWithMessagesProvider(sessionId));
  return sessionAsync.valueOrNull?.session.bridgeLastRun;
});

/// Gets the bridge agent's own SDK session ID for a given chat session.
///
/// The bridge session is 1:1 with the chat session and accumulates full
/// conversational context across all cadence runs.
final bridgeSessionIdProvider =
    Provider.autoDispose.family<String?, String>((ref, chatSessionId) {
  final sessionAsync = ref.watch(sessionWithMessagesProvider(chatSessionId));
  return sessionAsync.valueOrNull?.session.bridgeSessionId;
});

/// Returns a function that triggers a manual bridge run for a session.
final triggerBridgeProvider =
    Provider<Future<void> Function(String)>((ref) {
  final service = ref.watch(chatServiceProvider);
  return service.triggerBridge;
});

/// Fetches the bridge agent's conversation transcript for a given chat session.
///
/// Messages are loaded from the dedicated bridge/messages endpoint, which
/// reads the JSONL directly — the bridge session is never in SQLite so it
/// won't appear in the chat list.
final bridgeMessagesProvider =
    FutureProvider.autoDispose.family<List<BridgeMessage>, String>(
  (ref, chatSessionId) async {
    final service = ref.watch(chatServiceProvider);
    final rawMessages = await service.getBridgeMessages(chatSessionId);
    return rawMessages.map((m) => BridgeMessage.fromJson(m)).toList();
  },
);
