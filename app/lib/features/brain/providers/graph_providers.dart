import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart'
    show apiKeyProvider;
import '../services/graph_service.dart';

/// Provider for GraphService.
final graphServiceProvider = Provider<GraphService>((ref) {
  final baseUrl = ref.watch(aiServerUrlProvider).valueOrNull ?? 'http://localhost:3333';
  final apiKey = ref.watch(apiKeyProvider).valueOrNull;
  final service = GraphService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Schema from /api/graph/schema.
/// Returns {node_tables: [...], rel_tables: [...]}
final graphSchemaProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.watch(graphServiceProvider).getSchema();
});

/// Selected table name for the graph navigator.
final graphSelectedTableProvider = StateProvider<String?>((ref) => null);

/// Data for a specific table — keyed by table name.
/// Only fetches for tables with a known endpoint.
final graphTableDataProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, tableName) async {
    final service = ref.watch(graphServiceProvider);
    switch (tableName) {
      case 'Parachute_Session':
        return service.getSessions(limit: 50);
      case 'Parachute_ContainerEnv':
        return service.getContainerEnvs(limit: 50);
      case 'Journal_Entry':
        return service.getDailyEntries(limit: 50);
      default:
        // No data endpoint for this table — return empty rows
        return {'rows': [], 'count': 0, 'note': 'No data endpoint for $tableName'};
    }
  },
);
