---
status: pending
priority: p2
issue_id: 75
tags: [code-review, quality, python]
dependencies: []
---

# Atomic Write Pattern Duplicated 3 Times

## Problem Statement

The `mkstemp` + `os.write` + `os.fsync` + `os.rename` pattern is implemented identically in three places. This creates risk of divergent error handling if any copy is modified independently.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence 92), architecture-strategist (P3, confidence 82)
- **Location**: `core/plugin_installer.py:73-86` (_write_manifest), `core/plugin_installer.py:315-331` (_atomic_write_json), `api/mcp.py:78-97` (save_mcp_config)
- **Evidence**: _write_manifest could simply call _atomic_write_json. save_mcp_config reimplements independently.

## Proposed Solutions

### Solution A: Extract to shared utility (Recommended)
Create `lib/atomic_io.py` with `atomic_write_json(path, data)`.
- **Pros**: DRY, consistent error handling, one place to maintain
- **Cons**: New file
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `core/plugin_installer.py`, `api/mcp.py`, new `lib/atomic_io.py`

## Acceptance Criteria
- [ ] Single atomic write utility in lib/
- [ ] All 3 call sites use it

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | mcp.py also missing trailing newline |

## Resources
- PR: #75
