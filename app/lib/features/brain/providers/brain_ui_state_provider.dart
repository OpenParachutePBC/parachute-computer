import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_filter.dart';
import '../models/brain_schema.dart';
import 'brain_service_provider.dart';
// brainQueryServiceProvider exported from brain_service_provider.dart

/// Currently selected entity type in the sidebar/tabs.
/// Null means no type selected (e.g., still loading schemas).
final brainSelectedTypeProvider = StateProvider<String?>((ref) => null);

/// Current search query for filtering entities.
final brainSearchQueryProvider = StateProvider<String>((ref) => '');

/// Selected entity IRI for the inline detail pane (wide layout only).
/// Null = detail pane closed.
final brainSelectedEntityProvider = StateProvider<String?>((ref) => null);

/// Current layout mode — written by BrainHomeScreen's LayoutBuilder, read by child widgets.
/// Only BrainHomeScreen should write to this provider.
final brainLayoutModeProvider =
    StateProvider<BrainLayoutMode>((ref) => BrainLayoutMode.mobile);

/// Layout mode for the Brain screen.
enum BrainLayoutMode { mobile, wide }

/// Schema types from /api/brain/types — includes entity counts per type.
/// Use this for the sidebar (needs counts). brainSchemaListProvider is legacy.
final brainSchemaDetailProvider =
    FutureProvider<List<BrainSchemaDetail>>((ref) async {
  final service = ref.watch(brainServiceProvider);
  return service.listSchemaTypes();
});

/// Active filter conditions for the currently selected type.
/// NotifierProvider enables atomic add/remove operations.
final brainActiveFiltersProvider =
    NotifierProvider<BrainFilterNotifier, List<BrainFilterCondition>>(
  BrainFilterNotifier.new,
);

class BrainFilterNotifier extends Notifier<List<BrainFilterCondition>> {
  @override
  List<BrainFilterCondition> build() {
    ref.watch(brainSelectedTypeProvider); // auto-clear filters on type switch
    return [];
  }

  void add(BrainFilterCondition condition) =>
      state = [...state, condition];

  void remove(int index) {
    final updated = [...state];
    updated.removeAt(index);
    state = updated;
  }

  void clear() => state = [];
}

/// Saved filter queries loaded from backend.
final brainSavedQueriesProvider = FutureProvider.autoDispose<List<SavedQuery>>(
  (ref) => ref.watch(brainQueryServiceProvider).loadQueries(),
);
