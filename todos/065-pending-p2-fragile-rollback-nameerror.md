---
status: pending
priority: p2
issue_id: 75
tags: [code-review, quality, python]
dependencies: []
---

# Fragile Rollback via NameError Catch

## Problem Statement

The install rollback uses `try: installed; except NameError: pass` to check if `installed` is defined. This is fragile — if `_rollback_installed_files` itself raises a `NameError`, it's silently swallowed.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence 88)
- **Location**: `computer/parachute/core/plugin_installer.py:487-491`
- **Evidence**: `installed` variable existence checked via NameError catch with `noqa: B018`

## Proposed Solutions

### Solution A: Initialize variable before try block (Recommended)
```python
installed = None
try:
    ...
    installed = _install_files(...)
    ...
except Exception:
    if installed is not None:
        _rollback_installed_files(...)
    raise
```
- **Pros**: Clear, no NameError swallowing risk
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] No NameError-based variable existence checks
- [ ] Rollback errors not silently swallowed

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | noqa suppression hides fragile pattern |

## Resources
- PR: #75
