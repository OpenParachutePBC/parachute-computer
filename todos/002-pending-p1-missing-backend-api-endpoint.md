---
status: pending
priority: p1
issue_id: 100
tags: [code-review, backend, python, api]
dependencies: []
---

# Missing Backend API Endpoint: GET /api/brain_v2/entities/by_id

## Problem Statement

The Flutter app calls `GET /api/brain_v2/entities/by_id?id={entity_id}` but this endpoint doesn't exist in the backend router. This causes all entity detail views to fail with 404 errors, making the entire Brain v2 UI non-functional.

**Impact**: Users cannot view entity details - clicking any entity card results in an error screen. This blocks the primary use case of the Brain v2 UI.

## Findings

**Source**: architecture-strategist agent
**Confidence**: 99
**Location**:
- Frontend: `app/lib/features/brain_v2/services/brain_v2_service.dart:84-90`
- Backend: `computer/modules/brain_v2/module.py:67-181`

**Evidence**:
- Frontend code clearly calls the endpoint (line 84-90)
- Backend router only has PUT and DELETE for `{entity_id}`, no GET route
- No GET route with query parameter pattern exists

Frontend call:
```dart
Future<BrainV2Entity?> getEntity(String id) async {
  final uri = Uri.parse('$baseUrl/api/brain_v2/entities/by_id').replace(
    queryParameters: {'id': id},
  );
  final response = await client.get(uri, headers: _headers);
```

Backend routes (existing):
- `GET /api/brain_v2/entities` - list all (exists)
- `PUT /api/brain_v2/entities/{entity_id}` - update (exists)
- `DELETE /api/brain_v2/entities/{entity_id}` - delete (exists)
- `GET /api/brain_v2/entities/by_id` - **MISSING**

## Proposed Solutions

### Option 1: Add query parameter endpoint (Matches frontend)
**Implementation**:
```python
@router.get("/api/brain_v2/entities/by_id")
async def get_entity_by_id(
    id: str = Query(..., description="Entity IRI"),
    client: Optional[Client] = Depends(get_db_client),
) -> Dict[str, Any]:
    """Retrieve a single entity by IRI."""
    if client is None:
        raise HTTPException(status_code=503, detail="TerminusDB not available")

    query = f"""
        WOQL.triple("{id}", v("Property"), v("Value"))
    """
    result = client.query(query)

    if not result.get("bindings"):
        raise HTTPException(status_code=404, detail=f"Entity not found: {id}")

    # Transform bindings to entity format
    entity = _transform_entity_result(result["bindings"], id)
    return entity
```

**Pros**:
- No frontend changes needed
- Matches existing API call pattern
- Simple query parameter pattern

**Cons**:
- Inconsistent with RESTful path parameter pattern
- Two different patterns for entity access

**Effort**: Small (30 minutes)
**Risk**: Very Low

### Option 2: Use path parameter endpoint (RESTful, recommended)
**Implementation**:

Backend:
```python
@router.get("/api/brain_v2/entities/{entity_id}")
async def get_entity(
    entity_id: str,
    client: Optional[Client] = Depends(get_db_client),
) -> Dict[str, Any]:
    """Retrieve a single entity by ID."""
    # Same implementation as Option 1
```

Frontend change:
```dart
Future<BrainV2Entity?> getEntity(String id) async {
  final uri = Uri.parse('$baseUrl/api/brain_v2/entities/${Uri.encodeComponent(id)}');
  final response = await client.get(uri, headers: _headers);
```

**Pros**:
- RESTful pattern (consistent with PUT/DELETE)
- Single pattern for entity operations
- Better API design

**Cons**:
- Requires frontend change (one line)

**Effort**: Small (30 minutes backend + 5 minutes frontend)
**Risk**: Very Low

### Option 3: Support both patterns
**Implementation**: Add both endpoints, sharing implementation

**Pros**:
- Maximum compatibility
- No frontend changes needed
- Future-proof for API versioning

**Cons**:
- Maintenance burden of two endpoints
- Unnecessary complexity

**Effort**: Medium (45 minutes)
**Risk**: Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `computer/modules/brain_v2/module.py` (add route around line 67)
- `app/lib/features/brain_v2/services/brain_v2_service.dart` (line 84-90, change if using Option 2)

**Affected Components**:
- BrainV2EntityDetailScreen (won't load without this)
- BrainV2RelationshipChip (shows entity references)
- brainV2EntityDetailProvider (fetches via this endpoint)

**Database Changes**: None (read-only query)

**API Changes**: New endpoint `GET /api/brain_v2/entities/by_id` or `GET /api/brain_v2/entities/{entity_id}`

## Acceptance Criteria

- [ ] Backend endpoint exists and returns entity data
- [ ] Frontend can successfully fetch entity details
- [ ] Entity detail screen loads without 404 errors
- [ ] Relationship chips can fetch referenced entities
- [ ] Error handling for non-existent entities (404)
- [ ] Integration test covers entity retrieval flow

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Frontend calls endpoint that doesn't exist in backend
- **Source**: architecture-strategist agent (confidence: 99)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Backend Module**: `computer/modules/brain_v2/module.py`
- **Frontend Service**: `app/lib/features/brain_v2/services/brain_v2_service.dart`
- **TerminusDB Docs**: https://terminusdb.com/docs/
