import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/skill_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches available skills from the server.
final skillsProvider = FutureProvider.autoDispose<List<SkillInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getSkills();
});

/// Provider that fetches full skill detail by name (content, version, files, etc.).
final skillDetailProvider =
    FutureProvider.autoDispose.family<SkillInfo, String>((ref, name) async {
  final service = ref.watch(chatServiceProvider);
  return service.getSkillDetail(name);
});
