---
status: complete
priority: p2
issue_id: 40
tags: [code-review, type-safety, python]
dependencies: []
---

# `display_path` Has Mixed Type: `Path | str`

## Problem Statement

The `display_path` variable in the working directory framing block can be either a `PurePosixPath` (from `relative_to()`) or a `str` (from `.name`). While this works in the f-string due to implicit `__str__()`, it creates type ambiguity that would fail strict type checking and could break if the variable is used in path operations later.

## Findings

- **Source**: python-reviewer
- **Location**: `computer/parachute/core/orchestrator.py:1336-1339`
- **Evidence**:
  ```python
  try:
      display_path = wd_path.relative_to(self.vault_path)  # Returns Path
  except ValueError:
      display_path = wd_path.name  # Returns str
  ```

## Proposed Solutions

### Solution A: Normalize to `str` explicitly (Recommended)
```python
try:
    display_path = str(wd_path.relative_to(self.vault_path))
except ValueError:
    display_path = wd_path.name
```
- **Pros**: Clean type (`str` throughout), mypy-safe, prevents future misuse
- **Cons**: One extra `str()` call (negligible)
- **Effort**: Small (add 4 characters)
- **Risk**: None

## Recommended Action

Solution A — wrap `relative_to()` result in `str()`.

## Technical Details

- **Affected files**: `computer/parachute/core/orchestrator.py`
- **Line**: 1336

## Acceptance Criteria

- [ ] `display_path` is always `str` type
- [ ] f-string output unchanged

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Identified during PR #40 Python review | Mixed types in path variables are a common source of subtle bugs |

## Resources

- PR: #40
