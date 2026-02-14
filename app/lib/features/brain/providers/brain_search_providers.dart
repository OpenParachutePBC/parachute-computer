import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_entity.dart';
import '../models/brain_search_result.dart';
import 'brain_service_provider.dart';

/// Current search query for the Brain tab.
final brainSearchQueryProvider = StateProvider<String>((ref) => '');

/// Search results based on the current query.
///
/// Automatically refetches when the query changes.
/// Returns null when no query is entered.
final brainSearchResultsProvider =
    FutureProvider.autoDispose<BrainSearchResult?>((ref) async {
  final query = ref.watch(brainSearchQueryProvider);
  if (query.trim().isEmpty) return null;

  final service = ref.watch(brainServiceProvider);
  if (service == null) return null;

  return service.search(query);
});

/// Fetch a single entity by para ID.
final brainEntityDetailProvider =
    FutureProvider.family<BrainEntity?, String>((ref, paraId) async {
  final service = ref.watch(brainServiceProvider);
  if (service == null) return null;

  return service.getEntity(paraId);
});
