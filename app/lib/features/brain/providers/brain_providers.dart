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

/// Schema from /api/brain/schema.
/// Returns {node_tables: [...], rel_tables: [...]}
final brainSchemaProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.watch(brainServiceProvider).getSchema();
});

/// Selected table name for the schema inspector (dev/debug view).
final brainSelectedTableProvider = StateProvider<String?>((ref) => null);

/// Data for a specific table — keyed by table name.
/// Only fetches for tables with a known endpoint.
final brainTableDataProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, tableName) async {
    final service = ref.watch(brainServiceProvider);
    switch (tableName) {
      case 'Chat':
        return service.getSessions(limit: 50);
      case 'Project':
        return service.getProjects(limit: 50);
      case 'Note':
        return service.getDailyEntries(limit: 50);
      default:
        return {'rows': [], 'count': 0, 'note': 'No data endpoint for $tableName'};
    }
  },
);

/// Memory feed filter — 'all', 'sessions', or 'notes'.
final brainMemoryFilterProvider = StateProvider<String>((ref) => 'all');

/// Search query for the memory feed.
final brainMemorySearchProvider = StateProvider<String>((ref) => '');

/// Unified memory feed — sessions + notes, chronological.
/// Keyed by (filter, search) encoded as a record.
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
