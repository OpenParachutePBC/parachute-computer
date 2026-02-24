import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/curator_run.dart';
import '../models/chat_session.dart';
import 'chat_session_providers.dart';
import 'chat_message_providers.dart';

/// Derives the curator last run for the current active session.
///
/// Returns null if no session is active or if the curator hasn't run yet.
/// Re-evaluates whenever the current session's state changes, which happens
/// automatically after each stream completes (session metadata is refreshed).
final curatorLastRunProvider = Provider.autoDispose<CuratorRun?>((ref) {
  final sessionId = ref.watch(currentSessionIdProvider);
  if (sessionId == null) return null;

  // Read curator_last_run from the active session's metadata.
  // The chatMessagesProvider holds the current session object.
  final chatState = ref.watch(chatMessagesProvider);
  final session = chatState.currentSession;
  return session?.curatorLastRun;
});
