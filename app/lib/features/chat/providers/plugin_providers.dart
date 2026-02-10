import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_info.dart';
import '../models/plugin_info.dart';
import '../models/skill_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches installed plugins from the server.
final pluginsProvider = FutureProvider.autoDispose<List<PluginInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getPlugins();
});

/// Provider that fetches a skill from a specific plugin.
/// Key format: "slug:skillName"
final pluginSkillDetailProvider =
    FutureProvider.autoDispose.family<SkillInfo, String>((ref, key) async {
  final parts = key.split(':');
  final slug = parts[0];
  final name = parts.sublist(1).join(':');
  final service = ref.watch(chatServiceProvider);
  return service.getPluginSkill(slug, name);
});

/// Provider that fetches an agent from a specific plugin.
/// Key format: "slug:agentName"
final pluginAgentDetailProvider =
    FutureProvider.autoDispose.family<AgentInfo, String>((ref, key) async {
  final parts = key.split(':');
  final slug = parts[0];
  final name = parts.sublist(1).join(':');
  final service = ref.watch(chatServiceProvider);
  return service.getPluginAgent(slug, name);
});
