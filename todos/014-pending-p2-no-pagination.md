---
status: pending
priority: p2
issue_id: 100
tags: [code-review, performance, scalability, pagination]
dependencies: []
---

# Missing Pagination: Loads All Entities at Once

## Problem Statement

Entity list screen fetches ALL entities for a type in a single request with no pagination, lazy loading, or virtualization. For entity types with 1000+ items, this causes slow initial load, high memory usage, and poor scrolling performance.

**Impact**: Unusable with large datasets. Initial load can take 10+ seconds for 5000 entities. Memory bloat from loading all data at once. Scroll performance degrades with list size.

## Findings

**Source**: performance-oracle agent
**Confidence**: 88
**Location**: `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart:55`

**Evidence**:
```dart
// Line 55 - Loads all entities at once
final entitiesAsync = ref.watch(brainV2EntityListProvider(widget.entityType));

// Provider implementation (brain_v2_providers.dart)
final brainV2EntityListProvider = FutureProvider.autoDispose.family<
    List<BrainV2Entity>, String>((ref, entityType) async {
  final service = ref.read(brainV2ServiceProvider);
  if (service == null) return [];
  return await service.listEntities(entityType);  // ← Fetches ALL
});
```

**Performance Impact**:
```
5000 entities × 2KB per entity = 10MB payload
+ JSON parsing
+ Widget tree construction
= 8-15 second initial load
```

**Memory Impact**:
```
5000 entities in memory
+ Cached in provider
+ Widget state
= High memory pressure on mobile devices
```

## Proposed Solutions

### Option 1: Cursor-based pagination with infinite scroll (Recommended)
**Implementation**:

Backend:
```python
@router.get("/api/brain_v2/entities")
async def list_entities(
    entity_type: str = None,
    limit: int = Query(50, le=200),
    cursor: str = None,  # Last entity ID from previous page
    client: Optional[Client] = Depends(get_db_client),
) -> Dict[str, Any]:
    """List entities with pagination."""
    query = build_paginated_query(entity_type, limit, cursor)
    results = await client.query(query)

    next_cursor = None
    if len(results) == limit:
        next_cursor = results[-1]["@id"]

    return {
        "entities": results,
        "next_cursor": next_cursor,
        "has_more": next_cursor is not None,
    }
```

Frontend:
```dart
// Use infinite scroll package
class BrainV2EntityListScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<BrainV2EntityListScreen> createState() => _State();
}

class _State extends ConsumerState<BrainV2EntityListScreen> {
  final _scrollController = ScrollController();
  final _entities = <BrainV2Entity>[];
  String? _nextCursor;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitialPage();
  }

  Future<void> _loadInitialPage() async {
    final result = await service.listEntities(
      entityType: widget.entityType,
      limit: 50,
    );
    setState(() {
      _entities.addAll(result.entities);
      _nextCursor = result.nextCursor;
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore && _nextCursor != null) {
        _loadMore();
      }
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _nextCursor == null) return;

    setState(() => _isLoadingMore = true);

    final result = await service.listEntities(
      entityType: widget.entityType,
      limit: 50,
      cursor: _nextCursor,
    );

    setState(() {
      _entities.addAll(result.entities);
      _nextCursor = result.nextCursor;
      _isLoadingMore = false;
    });
  }
}
```

**Pros**:
- Fast initial load (50 items vs 5000)
- Low memory footprint
- Smooth infinite scroll UX
- Scales to millions of entities

**Cons**:
- Backend changes required
- More complex state management
- Pagination state to manage

**Effort**: Large (5-6 hours backend + frontend)
**Risk**: Low

### Option 2: Offset-based pagination with page buttons
**Implementation**: Traditional page 1, 2, 3... navigation

**Pros**:
- Simpler backend implementation
- Familiar UX pattern

**Cons**:
- Poor UX for mobile (page buttons)
- Offset pagination slower at high offsets
- Less fluid than infinite scroll

**Effort**: Large (4-5 hours)
**Risk**: Low

### Option 3: Lazy loading with Flutter's ListView.builder
**Implementation**: Keep current API, use lazy widget building

**Pros**:
- No backend changes
- Widgets built on-demand

**Cons**:
- Still loads all data upfront
- Doesn't solve network/memory problem
- Only optimizes widget rendering

**Effort**: Small (1 hour)
**Risk**: Very Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart` (add scroll listener, pagination state)
- `app/lib/features/brain_v2/services/brain_v2_service.dart` (add pagination params)
- `app/lib/features/brain_v2/providers/brain_v2_providers.dart` (paginated provider)
- `computer/modules/brain_v2/module.py` (add pagination to list endpoint)

**Pagination Strategy**:
- Page size: 50 entities
- Preload trigger: 200px from bottom
- Loading indicator at list bottom
- Pull-to-refresh for first page

**Database Changes**: May need index on entity order field

**API Changes**: Add `limit` and `cursor` query params to GET /api/brain_v2/entities

## Acceptance Criteria

- [ ] Initial load fetches only first page (50 entities)
- [ ] Scrolling near bottom automatically loads next page
- [ ] Loading indicator shows during page fetch
- [ ] No duplicate entities from pagination
- [ ] Works with search/filter (resets pagination)
- [ ] Performance test: 10,000 entities → initial load <2 seconds
- [ ] Memory test: 10,000 entities → peak memory <100MB

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: No pagination, loads all entities at once
- **Source**: performance-oracle agent (confidence: 88)
- **Pattern**: Common scalability issue in list UIs

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Infinite Scroll**: https://pub.dev/packages/infinite_scroll_pagination
- **Cursor Pagination**: https://jsonapi.org/profiles/ethanresnick/cursor-pagination/
- **ListView.builder**: https://api.flutter.dev/flutter/widgets/ListView/ListView.builder.html
