import '../models/brain_filter.dart';
import 'brain_service.dart';

/// Thin HTTP client for saved filter queries.
///
/// Delegates to [BrainService] — Flutter must NOT write vault/.brain/ directly.
/// Backend handles all file I/O for saved queries.
class BrainQueryService {
  final BrainService _brain;
  BrainQueryService(this._brain);

  Future<List<SavedQuery>> loadQueries() => _brain.listSavedQueries();

  Future<String> saveQuery(
    String name,
    String entityType,
    List<BrainFilterCondition> filters,
  ) =>
      _brain.saveQuery(name: name, entityType: entityType, filters: filters);

  Future<void> deleteQuery(String id) => _brain.deleteQuery(id);
}
