---
status: pending
priority: p2
issue_id: 91
tags: [code-review, security, python, matrix]
dependencies: []
---

# TOCTOU race on `allowed_rooms` list mutation during approval

## Problem Statement

When a bridged room is approved in `approve_pairing()`, the in-memory `connector.allowed_rooms` list is mutated (appended to) outside of any lock, while the YAML config file is written under `_config_lock`. This creates two issues:

1. **Race condition**: If two approvals happen concurrently, both may append to the list without coordination, and the YAML write may only capture one.
2. **Non-atomic sync**: The in-memory list and the YAML file can temporarily (or permanently) diverge — if the YAML write fails, the in-memory list already has the new room.

## Findings

- **Source**: security-sentinel (P2, confidence: 82), architecture-strategist (P2, confidence: 88)
- **Location**: `computer/parachute/api/bots.py:502-510` (in-memory mutation) and `bots.py:563-587` (`_add_to_allowlist` with `_config_lock`)
- **Evidence**: In `approve_pairing()`, lines 502-510 mutate `connector.allowed_rooms` directly without holding `_config_lock`. The `_add_to_allowlist()` call at line 512 acquires `_config_lock` for the YAML write, but the in-memory mutation is already done.

## Proposed Solutions

### Solution A: Move in-memory mutation inside `_add_to_allowlist` (Recommended)
Pass the connector to `_add_to_allowlist` and do both the YAML write and in-memory mutation under the same lock:
```python
async def _add_to_allowlist(platform, identifier, *, is_room=False, connector=None):
    async with _config_lock:
        # ... YAML write ...
        if is_room and connector and hasattr(connector, "allowed_rooms"):
            if identifier not in connector.allowed_rooms:
                connector.allowed_rooms.append(identifier)
```

- **Pros**: Atomic update, simple
- **Cons**: `_add_to_allowlist` takes an optional connector param
- **Effort**: Small
- **Risk**: Low

### Solution B: Accept the race as low-probability
Concurrent approvals are extremely rare (human-initiated, one at a time). Document the limitation.

- **Pros**: No code change
- **Cons**: Leaves a known race condition
- **Effort**: None
- **Risk**: Accepted risk

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/bots.py`

## Acceptance Criteria

- [ ] In-memory and YAML mutations happen atomically (or document accepted risk)
- [ ] No divergence between in-memory `allowed_rooms` and YAML after approval

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
