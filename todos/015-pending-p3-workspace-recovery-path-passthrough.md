---
status: pending
priority: p3
issue_id: "29"
tags: [code-review, chat, workspace, tech-debt]
dependencies: []
---

# Recovery path doesn't pass workspaceId to sendMessage

## Problem Statement

`recoverSession` at `chat_message_providers.dart:1599` calls `sendMessage(message: unavailableInfo.pendingMessage)` without passing `workspaceId`. This means the retry falls back to reading `activeWorkspaceProvider` (sidebar filter), which could be stale if the user changed the sidebar between the original send and the retry.

**Mitigated by:** Server-side fallback at `orchestrator.py:279` loads workspace from session's stored `workspace_id`.

**Why this is P3, not P2:** The server fallback makes this safe in practice. The race window is narrow (user must change sidebar filter between a session error and clicking retry). Filed as tech debt for completeness.

## Findings

- Discovered by: code-simplicity-reviewer, flutter-reviewer, architecture-strategist
- Location: `app/lib/features/chat/providers/chat_message_providers.dart:1599`
- The `??` fallback at line 1152 preserves the old behavior for this caller

## Proposed Solutions

### Option A: Store workspace in SessionUnavailableInfo (Recommended)
- Capture `activeWorkspace` at the time of the original failure
- Store it in `SessionUnavailableInfo` alongside `pendingMessage`
- Pass it through on retry
- **Effort:** Small (~4 lines)
- **Risk:** Low

### Option B: Remove fallback entirely
- Remove `?? _ref.read(activeWorkspaceProvider)` from line 1152
- Make `workspaceId` the only source
- Fix all callers (only 2)
- **Effort:** Small (~6 lines)
- **Risk:** Low, but changes semantics for existing sessions

## Acceptance Criteria

- [ ] `recoverSession` passes workspace explicitly to `sendMessage`
- [ ] No fallback read of `activeWorkspaceProvider` inside `sendMessage`
- [ ] `flutter analyze` passes

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Filed during PR review of fix/workspace-passthrough-29 | Pre-existing issue, not introduced by this PR |

## Resources

- PR: fix/workspace-passthrough-29
- Issue: #29
- Related: `activeWorkspaceProvider` SRP violation (separate tech debt)
