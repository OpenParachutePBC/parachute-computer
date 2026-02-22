import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_entity.dart';
import 'brain_service_provider.dart';

/// Query entities by type with pagination.
///
/// Usage: ref.watch(brainEntityListProvider('Person'))
final brainEntityListProvider = FutureProvider.autoDispose
    .family<List<BrainEntity>, String>((ref, type) async {
  final service = ref.watch(brainServiceProvider);
  return service.queryEntities(type, limit: 100);
});

/// Fetch a single entity by ID.
///
/// Usage: ref.watch(brainEntityDetailProvider('Person/Alice'))
final brainEntityDetailProvider =
    FutureProvider.autoDispose.family<BrainEntity?, String>((ref, id) async {
  final service = ref.watch(brainServiceProvider);
  return service.getEntity(id);
});
