---
status: pending
priority: p2
issue_id: 100
tags: [code-review, performance, n-plus-one, optimization]
dependencies: []
---

# N+1 Query Pattern: Individual Relationship Fetches

## Problem Statement

`BrainV2RelationshipChip` fetches each relationship entity individually using `brainV2EntityDetailProvider(entityId)`. When an entity has N relationships, this triggers N+1 HTTP requests (1 for the entity + N for relationships), causing severe performance degradation for entities with many relationships.

**Impact**: Viewing entities with 10+ relationships takes multiple seconds due to sequential HTTP requests. Poor user experience with visible loading states for each chip. Server load increases proportionally with relationship count.

## Findings

**Source**: performance-oracle agent
**Confidence**: 95
**Location**: `app/lib/features/brain_v2/widgets/brain_v2_relationship_chip.dart:21`

**Evidence**:
```dart
// Line 21 - Each chip fetches independently
final entityAsync = ref.watch(brainV2EntityDetailProvider(entityId));
```

**Example Performance Problem**:
```
Entity with 15 relationships:
- Request 1: GET /api/brain_v2/entities/main_entity (100ms)
- Request 2: GET /api/brain_v2/entities/rel_1 (100ms)
- Request 3: GET /api/brain_v2/entities/rel_2 (100ms)
... 15 more requests
= 1.6 seconds total (blocking UI)
```

With batch endpoint:
```
- Request 1: GET /api/brain_v2/entities/main_entity (100ms)
- Request 2: POST /api/brain_v2/entities/batch {"ids": [...]} (150ms)
= 250ms total (6x faster)
```

## Proposed Solutions

### Option 1: Batch fetch endpoint (Recommended)
**Implementation**:

Backend:
```python
@router.post("/api/brain_v2/entities/batch")
async def get_entities_batch(
    entity_ids: List[str],
    client: Optional[Client] = Depends(get_db_client),
) -> Dict[str, Any]:
    """Fetch multiple entities in one request."""
    results = {}
    for entity_id in entity_ids:
        try:
            results[entity_id] = await _fetch_entity(client, entity_id)
        except Exception:
            results[entity_id] = None
    return results
```

Frontend:
```dart
// New provider for batch fetching
final brainV2EntitiesBatchProvider = FutureProvider.autoDispose.family<
    Map<String, BrainV2Entity?>, List<String>>((ref, ids) async {
  final service = ref.watch(brainV2ServiceProvider);
  if (service == null) return {};
  return await service.getBatch(ids);
});

// Relationship widget uses batch
class BrainV2RelationshipsWidget extends ConsumerWidget {
  final List<String> entityIds;

  Widget build(context, ref) {
    final batchAsync = ref.watch(brainV2EntitiesBatchProvider(entityIds));
    return batchAsync.when(
      data: (entities) => Wrap(
        children: entityIds.map((id) {
          final entity = entities[id];
          return _buildChip(entity);
        }).toList(),
      ),
      ...
    );
  }
}
```

**Pros**:
- Dramatic performance improvement (10+ relationships)
- Single HTTP roundtrip
- Server can optimize batch queries
- Scalable solution

**Cons**:
- Backend endpoint required
- Frontend refactoring needed
- More complex than current approach

**Effort**: Large (3-4 hours backend + frontend)
**Risk**: Low

### Option 2: Optimistic rendering with lazy load
**Implementation**:
```dart
class BrainV2RelationshipChip extends ConsumerWidget {
  final String entityId;
  final String? displayName;  // Passed from parent if available

  Widget build(context, ref) {
    // Show optimistic UI immediately
    if (displayName != null) {
      return _buildChip(displayName);
    }

    // Lazy load full entity only on hover/tap
    final entityAsync = ref.watch(brainV2EntityDetailProvider(entityId));
    return entityAsync.when(...);
  }
}
```

**Pros**:
- No backend changes
- Immediate rendering if display name available
- Reduces unnecessary fetches

**Cons**:
- Still N+1 pattern if all names needed
- Requires parent to pass display names
- Doesn't solve root performance issue

**Effort**: Medium (1-2 hours)
**Risk**: Low

### Option 3: Client-side caching with stale-while-revalidate
**Implementation**: Use Riverpod's keepAlive + cache duration

**Pros**:
- Reduces duplicate fetches
- No backend changes

**Cons**:
- Still makes N requests on first load
- Only helps on repeated views
- Doesn't solve initial performance problem

**Effort**: Small (30 minutes)
**Risk**: Very Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/widgets/brain_v2_relationship_chip.dart` (line 21)
- `app/lib/features/brain_v2/services/brain_v2_service.dart` (add batch method)
- `computer/modules/brain_v2/module.py` (add batch endpoint)

**Affected Components**:
- BrainV2RelationshipChip (individual relationship rendering)
- BrainV2FieldWidget (renders arrays of relationships)
- Entity detail screen (shows related entities)

**Performance Impact**:
- Current: O(N) HTTP requests for N relationships
- Option 1: O(1) HTTP requests (batch)
- Option 2: O(N) but lazy/conditional
- Option 3: O(N) first time, O(0) cached

**Database Changes**: None (read-only optimization)

**API Changes**: New POST /api/brain_v2/entities/batch endpoint

## Acceptance Criteria

- [ ] Backend batch endpoint exists and returns multiple entities
- [ ] Frontend uses batch fetching for relationship arrays
- [ ] Entity detail screen with 15+ relationships loads in <500ms
- [ ] Network tab shows 1 batch request instead of N individual requests
- [ ] Error handling for partial batch failures
- [ ] Performance test: 50 relationships load without UI freeze

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: N+1 query pattern for relationship rendering
- **Source**: performance-oracle agent (confidence: 95)
- **Pattern**: Classic N+1 problem, common in graph data UIs

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **N+1 Pattern**: https://stackoverflow.com/questions/97197/what-is-the-n1-select-query-issue
- **Batch Fetching**: Common GraphQL/REST optimization technique
- **Location**: `brain_v2_relationship_chip.dart:21`
