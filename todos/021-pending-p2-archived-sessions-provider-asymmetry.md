---
status: done
priority: p2
issue_id: 50
tags: [code-review, flutter, error-handling, riverpod]
dependencies: []
---

# archivedSessionsProvider Asymmetry — Still Swallows Errors

## Problem Statement

PR #65 updated `chatSessionsProvider` to re-throw when both server and local fail, activating the existing error UI. However, `archivedSessionsProvider` in the same file still catches all errors and returns `[]`. This creates an asymmetric error handling pattern where active sessions show errors but archived sessions silently degrade.

## Findings

- **Source**: flutter-reviewer (90), architecture-strategist (90), pattern-recognition-specialist (92)
- **Location**: `app/lib/features/chat/providers/chat_session_providers.dart` — `archivedSessionsProvider`
- **Evidence**: Three agents independently flagged the same asymmetry. The archived sessions view would show an empty list with no error indication when the server is down.

## Proposed Solutions

### Solution A: Apply same pattern as chatSessionsProvider
Add local fallback + re-throw on total failure, matching the pattern used for active sessions.
- **Pros**: Consistent error handling, activates archived view's error UI
- **Cons**: Need to verify archived view has `.when(error:)` handler
- **Effort**: Small
- **Risk**: Low

### Solution B: Accept asymmetry — archived is lower priority
Archived sessions are rarely viewed. Silent degradation to empty list is acceptable.
- **Pros**: No code change needed
- **Cons**: Inconsistent pattern may confuse future maintainers
- **Effort**: None
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_session_providers.dart`
- **Components**: `archivedSessionsProvider`

## Acceptance Criteria

- [ ] `archivedSessionsProvider` error handling matches `chatSessionsProvider` pattern
- [ ] Archived sessions view shows error state when both server and local fail

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Three agents flagged independently |

## Resources

- PR: #65
- Issue: #50
