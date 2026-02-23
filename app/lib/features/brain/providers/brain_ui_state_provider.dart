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

/// Current layout mode — updated by BrainHomeScreen's LayoutBuilder.
/// Using an internal StateProvider + a public derived provider separates
/// the write side (LayoutBuilder) from the read side (child widgets).
final _brainLayoutModeStateProvider =
    StateProvider<BrainLayoutMode>((ref) => BrainLayoutMode.mobile);

final brainLayoutModeProvider = Provider<BrainLayoutMode>(
  (ref) => ref.watch(_brainLayoutModeStateProvider),
);

/// Layout mode for the Brain screen.
enum BrainLayoutMode { mobile, wide }

/// Expose the internal state provider notifier for LayoutBuilder to update.
final brainLayoutModeStateProvider = _brainLayoutModeStateProvider;

/// Schema types from /api/brain/types — includes entity counts per type.
/// Use this for the sidebar (needs counts). brainSchemaListProvider is legacy.
final brainSchemaDetailProvider =
    FutureProvider.autoDispose<List<BrainSchemaDetail>>((ref) async {
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
  List<BrainFilterCondition> build() => [];

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
  (ref) => ref.read(brainQueryServiceProvider).loadQueries(),
);
