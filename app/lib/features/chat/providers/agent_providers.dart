import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/connectivity_provider.dart'
    show isServerAvailableProvider;
import '../models/agent_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches available agents from the server.
///
/// Returns a list of agents from all sources (builtin, vault, custom).
/// Automatically refreshes when dependencies change.
/// Returns empty list if offline to avoid timeout.
final agentsProvider = FutureProvider.autoDispose<List<AgentInfo>>((ref) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return [];
  }

  final service = ref.watch(chatServiceProvider);
  return service.getAgents();
});

/// Provider that fetches full agent detail by name (system prompt, permissions, etc.).
/// Returns null if offline to avoid timeout.
final agentDetailProvider =
    FutureProvider.autoDispose.family<AgentInfo?, String>((ref, name) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return null;
  }

  final service = ref.watch(chatServiceProvider);
  return service.getAgentDetail(name);
});
