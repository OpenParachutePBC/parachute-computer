---
status: pending
priority: p2
issue_id: 75
tags: [code-review, quality, python]
dependencies: []
---

# HookRunner Retains ~100 Lines of Unreachable Code

## Problem Statement

After `discover()` was gutted to a no-op, `_hooks` and `_hook_modules` are never populated. This means `fire()` always returns early, `_execute`/`_safe_execute` are never called, and `get_registered_hooks()` always returns `[]`. ~100 lines of execution machinery are unreachable.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence 90)
- **Location**: `computer/parachute/core/hooks/runner.py:38-166`
- **Evidence**: `discover()` returns 0 without populating `_hooks`. `fire()` exits at `if not hooks: return`.

## Proposed Solutions

### Solution A: Strip to minimal internal bus
Keep only `fire()` with a `register()` method for programmatic hook registration (bot connectors).
- **Pros**: Clean, honest about what the class does
- **Effort**: Small
- **Risk**: Low

### Solution B: Delete execution methods, keep stubs
Remove `_execute`, `_safe_execute`, `_hook_modules`. Keep `fire()` as no-op.
- **Pros**: Minimal code
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/hooks/runner.py`

## Acceptance Criteria
- [ ] No unreachable methods in HookRunner
- [ ] Bot connector events still work (if register() added)

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Dead code left from Phase 2 demotion |

## Resources
- PR: #75
