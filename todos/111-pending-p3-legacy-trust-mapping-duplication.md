---
status: pending
priority: p3
issue_id: 62
tags: [code-review, python, flutter, quality, dry-principle]
created: 2026-02-21
---

# Legacy Trust Value Mapping Duplication Across Modules

## Problem Statement

The legacy trust level mapping (trusted→direct, untrusted→sandboxed, full→direct, vault→direct) is duplicated across Python backend and Flutter frontend instead of being maintained in a single location. While `computer/parachute/core/trust.py` provides normalization, the mapping dictionary itself appears in multiple places.

**Impact:** Low - Changes to legacy value support require updates in 2+ locations (Python and Dart).

**Introduced in:** Commit 8f93d13 (trust level rename)

## Findings

**Source:** Pattern Recognition Specialist (Confidence: 85)

**Duplicated mapping dictionaries:**

**Python side:**
```python
# computer/parachute/core/trust.py:8-14
_NORMALIZE_MAP = {
    "direct": "direct",
    "sandboxed": "sandboxed",
    "trusted": "direct",      # Legacy
    "untrusted": "sandboxed", # Legacy
    "full": "direct",         # Legacy
    "vault": "direct",        # Legacy
}
```

**Flutter side:**
```dart
// app/lib/features/settings/models/trust_level.dart:13-18
static TrustLevel fromString(String? value) {
  const legacy = {
    'full': 'direct',
    'vault': 'direct',
    'trusted': 'direct',
    'untrusted': 'sandboxed',
  };
  final mapped = legacy[value] ?? value;
  return TrustLevel.values.firstWhere((e) => e.name == mapped);
}
```

**Why this is acceptable (but could be better):**
1. Client and server need independent validation (can't share Python dict with Dart)
2. Mapping is stable and unlikely to change frequently
3. Both implementations are well-tested with migration v16

**Why this could still be improved:**
1. Adding a new legacy alias requires updating both files
2. No single source of truth documentation
3. Could drift if one is updated but not the other

## Proposed Solutions

### Solution 1: Document as Intentional Duplication (Recommended)

**Approach:** Accept duplication but add cross-references in comments to keep them in sync.

**Implementation:**
```python
# computer/parachute/core/trust.py
_NORMALIZE_MAP = {
    # NOTE: This mapping is duplicated in Flutter (app/lib/features/settings/models/trust_level.dart).
    # Keep both in sync when adding legacy aliases.
    "direct": "direct",
    "sandboxed": "sandboxed",
    "trusted": "direct",      # Legacy (pre-8f93d13)
    "untrusted": "sandboxed", # Legacy (pre-8f93d13)
    "full": "direct",         # Legacy (very old)
    "vault": "direct",        # Legacy (very old)
}
```

```dart
// app/lib/features/settings/models/trust_level.dart
static TrustLevel fromString(String? value) {
  // NOTE: This mapping is duplicated in Python (computer/parachute/core/trust.py).
  // Keep both in sync when adding legacy aliases.
  const legacy = {
    'full': 'direct',        // Legacy (very old)
    'vault': 'direct',       // Legacy (very old)
    'trusted': 'direct',     // Legacy (pre-8f93d13)
    'untrusted': 'sandboxed', // Legacy (pre-8f93d13)
  };
  final mapped = legacy[value] ?? value;
  return TrustLevel.values.firstWhere((e) => e.name == mapped);
}
```

**Pros:**
- Minimal code change (just comments)
- Maintains independence of client/server validation
- Developers are explicitly reminded to keep in sync

**Cons:**
- Still requires manual synchronization

**Effort:** Minimal (5 minutes)
**Risk:** Very low

### Solution 2: Generate Dart from Python at Build Time

**Approach:** Use code generation to create Dart enum from Python source of truth.

**Pros:**
- True single source of truth
- Impossible to drift

**Cons:**
- Adds build-time complexity
- Overkill for a stable 6-entry mapping
- Coupling between backend and frontend builds

**Effort:** Medium (2-3 hours)
**Risk:** Medium

### Solution 3: API Endpoint for Validation

**Approach:** Add `/api/trust/normalize` endpoint, have Flutter call it for validation.

**Pros:**
- Single source of truth (Python)
- Backend controls all validation logic

**Cons:**
- Requires network call for validation
- Flutter can't validate offline
- Unnecessary latency for simple mapping

**Effort:** Small (1 hour)
**Risk:** Low

## Recommended Action

Implement **Solution 1** - add cross-reference comments to both files. This is a stable mapping that rarely changes, so manual synchronization with explicit reminders is sufficient.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/trust.py:8-14`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/settings/models/trust_level.dart:13-18`

**Components:**
- Trust level normalization (Python)
- Trust level parsing (Flutter)

**Database changes:** None

## Acceptance Criteria

- [ ] Add comment to `trust.py` referencing Dart file
- [ ] Add comment to `trust_level.dart` referencing Python file
- [ ] Comments explain to keep mappings synchronized
- [ ] Verify both mappings are identical (they are)

## Work Log

- **2026-02-21**: Issue identified during pattern recognition analysis of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename (introduced current mapping)

**Similar patterns:**
- Database migrations also document schema changes in multiple places (Python SQL + Flutter models)
