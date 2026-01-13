import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/services/search/simple_text_search.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';

/// Provider for the simple text search service
/// Uses AsyncValue since JournalService requires async initialization
final simpleTextSearchProvider = FutureProvider<SimpleTextSearchService>((ref) async {
  final journalService = await ref.watch(journalServiceFutureProvider.future);
  return SimpleTextSearchService(journalService: journalService);
});

/// State for search results
class SearchState {
  final String query;
  final List<SimpleSearchResult> results;
  final bool isLoading;
  final String? error;
  final bool isInitialized;

  const SearchState({
    this.query = '',
    this.results = const [],
    this.isLoading = false,
    this.error,
    this.isInitialized = false,
  });

  SearchState copyWith({
    String? query,
    List<SimpleSearchResult>? results,
    bool? isLoading,
    String? error,
    bool? isInitialized,
  }) {
    return SearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

/// Notifier for managing search state
class SearchNotifier extends StateNotifier<SearchState> {
  final Ref _ref;

  SearchNotifier(this._ref) : super(const SearchState());

  /// Perform a search with the given query
  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      state = state.copyWith(query: '', results: [], isLoading: false);
      return;
    }

    state = state.copyWith(query: query, isLoading: true, error: null);

    try {
      final keywordService = _ref.read(simpleTextSearchProvider).valueOrNull;
      if (keywordService == null) {
        state = state.copyWith(isLoading: false, error: 'Search service not ready');
        return;
      }

      final results = await keywordService.search(query);
      state = state.copyWith(results: results, isLoading: false, isInitialized: true);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Search failed: $e',
      );
    }
  }

  /// Clear search results
  void clear() {
    state = state.copyWith(query: '', results: [], isLoading: false);
  }
}

/// Provider for search state
final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  return SearchNotifier(ref);
});
