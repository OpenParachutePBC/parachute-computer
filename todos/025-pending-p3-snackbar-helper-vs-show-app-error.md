---
status: pending
priority: p3
issue_id: 50
tags: [code-review, flutter, patterns]
dependencies: []
---

# `_showErrorSnackbar` Bypasses Existing `showAppError` Infrastructure

## Problem Statement

Fix 1 in PR #65 introduces a new `_showErrorSnackbar` helper in `journal_screen.dart` that creates snackbars directly via `ScaffoldMessenger`. The codebase has an existing `showAppError` utility (in `app/lib/core/widgets/error_snackbar.dart`) that may provide a consistent error display pattern. The new helper duplicates functionality.

## Findings

- **Source**: pattern-recognition-specialist (88)
- **Location**: `app/lib/features/daily/journal/screens/journal_screen.dart` — `_showErrorSnackbar` helper
- **Evidence**: The plan explicitly noted this was out-of-scope ("Raw `$e` in user-facing snackbars — Pre-existing pattern") and the new helper matches the pre-existing pattern used by `_addPhotoEntry`/`_addHandwritingEntry`. However, the pattern divergence is worth tracking.

## Proposed Solutions

### Solution A: Accept current pattern — track for future unification
The helper matches existing patterns in the same file. Unifying with `showAppError` is a separate cleanup.
- **Pros**: No change needed, matches existing code
- **Cons**: Divergent patterns persist
- **Effort**: None
- **Risk**: Low

### Solution B: Migrate all 6 catch blocks to use `showAppError`
Replace the new helper with the existing infrastructure across all journal CRUD operations.
- **Pros**: Uses shared infrastructure, consistent across app
- **Cons**: Scope creep beyond PR #65
- **Effort**: Medium
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/daily/journal/screens/journal_screen.dart`, `app/lib/core/widgets/error_snackbar.dart`

## Acceptance Criteria

- [ ] Decision made: accept current pattern or migrate to `showAppError`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Pre-existing pattern divergence, not introduced by this PR |

## Resources

- PR: #65
- Issue: #50
