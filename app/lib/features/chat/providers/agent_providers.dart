import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches available agents from the server.
///
/// Returns a list of agents from all sources (builtin, vault, custom).
/// Automatically refreshes when dependencies change.
final agentsProvider = FutureProvider.autoDispose<List<AgentInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getAgents();
});
