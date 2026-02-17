---
status: pending
priority: p3
issue_id: "29"
tags: [code-review, chat, workspace, architecture, tech-debt]
dependencies: []
---

# activeWorkspaceProvider violates Single Responsibility Principle

## Problem Statement

`activeWorkspaceProvider` at `workspace_providers.dart:30` serves three conflicting roles:
1. **Sidebar filter** — controls which sessions are shown in the session list
2. **New chat workspace** — determines what workspace a new chat is created in
3. **Send workspace** — consumed by `sendMessage()` to tag the API request

These are semantically distinct concerns. A user filtering the sidebar to browse "Work" sessions should not affect the workspace of an existing "Personal" chat session.

## Findings

- Discovered by: architecture-strategist (deepening phase and review phase)
- Location: `app/lib/features/chat/providers/workspace_providers.dart:30`
- The PR fix/workspace-passthrough-29 mitigates this by snapshotting the value at call time
- Long-term fix: add `workspaceId` to `ChatMessagesState` following `workingDirectory` pattern

## Proposed Solutions

### Option A: Add workspaceId to ChatMessagesState (Recommended)
- Add `workspaceId` field to `ChatMessagesState` (like `workingDirectory`)
- Populate from `ChatSession.workspaceId` during `loadSession()`
- Read from `state.workspaceId` in `sendMessage()` instead of `activeWorkspaceProvider`
- `activeWorkspaceProvider` becomes purely a sidebar filter
- **Effort:** Medium (~20 lines across 2 files)
- **Risk:** Low

### Option B: Add _pendingWorkspaceId to ChatScreen
- Follow the `_pendingAgentType` pattern
- Add `workspaceId` constructor param to `ChatScreen`
- Pass from `AgentHubScreen._startNewChat()`
- **Effort:** Medium (~15 lines across 3 files)
- **Risk:** Low, but inconsistent with `workingDirectory` which uses state

## Acceptance Criteria

- [ ] `sendMessage()` does not read `activeWorkspaceProvider`
- [ ] Sidebar filter changes do not affect existing session workspace
- [ ] New chats still get the correct workspace
- [ ] `flutter analyze` passes

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Filed during PR review of fix/workspace-passthrough-29 | Pre-existing architectural issue, partially mitigated by the PR |

## Resources

- PR: fix/workspace-passthrough-29
- Issue: #29
- Pattern reference: `workingDirectory` in `ChatMessagesState`
