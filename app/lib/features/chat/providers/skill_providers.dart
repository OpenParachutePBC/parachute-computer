import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/connectivity_provider.dart'
    show isServerAvailableProvider;
import '../models/skill_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches available skills from the server.
/// Returns empty list if offline to avoid timeout.
final skillsProvider = FutureProvider.autoDispose<List<SkillInfo>>((ref) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return [];
  }

  final service = ref.watch(chatServiceProvider);
  return service.getSkills();
});

/// Provider that fetches full skill detail by name (content, version, files, etc.).
/// Returns null if offline to avoid timeout.
final skillDetailProvider =
    FutureProvider.autoDispose.family<SkillInfo?, String>((ref, name) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return null;
  }

  final service = ref.watch(chatServiceProvider);
  return service.getSkillDetail(name);
});
