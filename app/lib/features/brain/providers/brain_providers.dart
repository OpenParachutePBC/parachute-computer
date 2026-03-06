import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart'
    show apiKeyProvider;
import '../services/brain_service.dart';

/// Provider for BrainService.
final brainServiceProvider = Provider<BrainService>((ref) {
  final baseUrl = ref.watch(aiServerUrlProvider).valueOrNull ?? 'http://localhost:3333';
  final apiKey = ref.watch(apiKeyProvider).valueOrNull;
  final service = BrainService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Memory feed filter — 'all', 'sessions', or 'notes'.
/// autoDispose: filter/search are ephemeral UI state, reset on nav.
final brainMemoryFilterProvider = StateProvider.autoDispose<String>((ref) => 'all');

/// Search query for the memory feed.
final brainMemorySearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Unified memory feed — sessions + notes, chronological.
/// Keyed by (filter, search) as a record.
final brainMemoryProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, (String, String)>(
  (ref, key) async {
    final (filter, search) = key;
    final service = ref.watch(brainServiceProvider);
    return service.getMemory(
      limit: 100,
      search: search.isEmpty ? null : search,
      type: filter == 'all' ? null : filter,
    );
  },
);
