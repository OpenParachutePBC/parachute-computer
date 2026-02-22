---
status: pending
priority: p2
issue_id: 100
tags: [code-review, performance, search, scalability]
dependencies: []
---

# Inefficient Client-Side Search: O(n×m) Filtering on Every Keystroke

## Problem Statement

`BrainV2EntityListScreen` performs client-side search by filtering ALL entities and ALL fields on every keystroke (lines 132-151). For large entity sets (1000+ entities), this causes UI lag and poor search responsiveness.

**Impact**: Search becomes unusably slow with large datasets. Typing in search box causes dropped frames and UI freezing. Scales poorly - 10,000 entities × 20 fields = 200,000 string comparisons per keystroke.

## Findings

**Source**: performance-oracle agent
**Confidence**: 90
**Location**: `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart:132-151`

**Evidence**:
```dart
// Lines 132-151 - O(n×m) search on every keystroke
final filteredEntities = searchQuery.isEmpty
    ? entities
    : entities.where((entity) {
        final name = entity.displayName.toLowerCase();
        final query = searchQuery.toLowerCase();

        // Search in name
        if (name.contains(query)) return true;

        // Search in tags (O(t) for t tags)
        if (entity.tags.any((tag) => tag.toLowerCase().contains(query))) {
          return true;
        }

        // Search in field values (O(f) for f fields)
        return entity.fields.values.any((value) {
          if (value == null) return false;
          return value.toString().toLowerCase().contains(query);
        });
      }).toList();
```

**Performance Breakdown**:
```
1000 entities × 10 fields × 20 chars per field = 200,000 string operations
On every keystroke with 300ms debounce = potential 3.3 searches/sec
= 660,000 string operations/sec during active search
```

## Proposed Solutions

### Option 1: Server-side search endpoint (Recommended for scale)
**Implementation**:

Backend:
```python
@router.get("/api/brain_v2/entities/search")
async def search_entities(
    q: str = Query(..., min_length=1),
    entity_type: Optional[str] = None,
    limit: int = Query(50, le=1000),
    client: Optional[Client] = Depends(get_db_client),
) -> List[Dict[str, Any]]:
    """Full-text search across entities."""
    # Use TerminusDB's built-in search if available, or implement
    # indexed search with substring matching
    query = f"""
        WOQL.and(
            triple(v("Entity"), "rdf:type", "{entity_type}"),
            sub_string(v("SearchText"), "{q}"),
            triple(v("Entity"), v("Property"), v("SearchText"))
        ).limit({limit})
    """
    return await client.query(query)
```

Frontend:
```dart
final brainV2SearchProvider = FutureProvider.autoDispose.family<
    List<BrainV2Entity>, (String type, String query)>((ref, params) async {
  final (entityType, query) = params;
  if (query.isEmpty) {
    return ref.watch(brainV2EntityListProvider(entityType)).value ?? [];
  }
  final service = ref.watch(brainV2ServiceProvider);
  return await service!.searchEntities(entityType, query);
});
```

**Pros**:
- Scales to millions of entities
- Can use database indexes
- Offloads computation to server
- Fast response even for large datasets

**Cons**:
- Requires backend endpoint
- Network latency for each search
- More complex implementation

**Effort**: Large (4-5 hours backend + frontend)
**Risk**: Low

### Option 2: Memoized search with better algorithm
**Implementation**:
```dart
// Add to state
Map<String, List<BrainV2Entity>>? _searchCache;

// In build
final filteredEntities = useMemo(() {
  if (searchQuery.isEmpty) return entities;

  // Check cache first
  if (_searchCache != null && _searchCache!.containsKey(searchQuery)) {
    return _searchCache![searchQuery]!;
  }

  // Build search index once
  final searchableEntities = entities.map((e) => (
    entity: e,
    searchText: [
      e.displayName.toLowerCase(),
      ...e.tags.map((t) => t.toLowerCase()),
      ...e.fields.values.map((v) => v?.toString().toLowerCase() ?? ''),
    ].join(' '),
  )).toList();

  // Fast substring search
  final query = searchQuery.toLowerCase();
  final results = searchableEntities
      .where((e) => e.searchText.contains(query))
      .map((e) => e.entity)
      .toList();

  // Cache result
  _searchCache ??= {};
  _searchCache![searchQuery] = results;

  return results;
}, [entities, searchQuery]);
```

**Pros**:
- No backend changes
- Faster than current approach
- Caches results

**Cons**:
- Still client-side limitation
- Cache memory overhead
- Doesn't scale past ~10K entities

**Effort**: Medium (2-3 hours)
**Risk**: Low

### Option 3: Incremental search with worker isolate
**Implementation**: Move search to background isolate

**Pros**:
- Doesn't block UI
- Can handle large datasets

**Cons**:
- Complex isolate communication
- Still O(n×m) computation
- Overkill for current needs

**Effort**: Large (6+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart` (lines 132-151)
- `app/lib/features/brain_v2/services/brain_v2_service.dart` (add search method)
- `computer/modules/brain_v2/module.py` (add search endpoint)

**Affected Components**:
- BrainV2EntityListScreen search functionality
- Entity filtering and display
- Search performance for all entity types

**Performance Characteristics**:
- Current: O(n × m) where n = entities, m = fields
- Option 1: O(log n) with database index
- Option 2: O(n × m) once, then O(1) from cache
- Option 3: O(n × m) in background thread

**Database Changes**: Option 1 may need search index

**API Changes**: New GET /api/brain_v2/entities/search endpoint

## Acceptance Criteria

- [ ] Search remains responsive with 1000+ entities
- [ ] No dropped frames during typing (60fps maintained)
- [ ] Search results appear within 300ms of keystroke
- [ ] Memory usage remains reasonable (no unbounded cache growth)
- [ ] Performance test: 10,000 entities with 20 fields each → smooth search
- [ ] Debounce prevents excessive backend calls (Option 1)

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Client-side search doesn't scale past ~1000 entities
- **Source**: performance-oracle agent (confidence: 90)
- **Pattern**: Common mistake in list UIs - client-side filtering for large datasets

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Flutter Performance**: https://docs.flutter.dev/perf/best-practices
- **Search Optimization**: Consider full-text search with TerminusDB capabilities
- **Location**: `brain_v2_entity_list_screen.dart:132-151`
