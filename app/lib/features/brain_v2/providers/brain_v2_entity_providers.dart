import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_v2_entity.dart';
import 'brain_v2_service_provider.dart';

/// Query entities by type with pagination.
///
/// Usage: ref.watch(brainV2EntityListProvider('Person'))
final brainV2EntityListProvider = FutureProvider.autoDispose
    .family<List<BrainV2Entity>, String>((ref, type) async {
  final service = ref.watch(brainV2ServiceProvider);
  if (service == null) return [];

  return service.queryEntities(type, limit: 100);
});

/// Fetch a single entity by ID.
///
/// Usage: ref.watch(brainV2EntityDetailProvider('Person/Alice'))
final brainV2EntityDetailProvider =
    FutureProvider.autoDispose.family<BrainV2Entity?, String>((ref, id) async {
  final service = ref.watch(brainV2ServiceProvider);
  if (service == null) return null;

  return service.getEntity(id);
});
