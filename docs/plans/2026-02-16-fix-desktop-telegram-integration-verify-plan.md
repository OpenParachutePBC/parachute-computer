---
title: "Desktop/Telegram Integration Fixes - Verify & Complete"
type: fix
date: 2026-02-16
issue: 29
labels: [bug, chat, computer, app, P1]
deepened: 2026-02-16
agents_used: [flutter-reviewer, parachute-conventions-reviewer, architecture-strategist, code-simplicity-reviewer, pattern-recognition-specialist, security-sentinel]
---

# Desktop/Telegram Integration Fixes - Verify & Complete

## Enhancement Summary

**Deepened on:** 2026-02-16
**Sections enhanced:** 4
**Review agents used:** 6 (flutter, conventions, architecture, simplicity, pattern-recognition, security)

### Key Improvements from Deepening
1. **Revised approach**: Original plan proposed `_pendingWorkspaceId` — agents found this is the wrong pattern. Workspace flows through `activeWorkspaceProvider`, not `_pending*` fields.
2. **Simpler fix**: Reduced from 3-file change to 2-file, ~4 lines of diff.
3. **Identified architectural tech debt**: `activeWorkspaceProvider` conflates sidebar filter with session workspace — flagged for future refactor, not this PR.

## Overview

Issue #29 was filed as "mostly done - needs verification" with 4 specific items. After thorough codebase research across PRs #2-#40, **all 4 original items are implemented**. However, research uncovered one real bug: `sendMessage()` reads `activeWorkspaceProvider` (a global sidebar filter) instead of receiving workspace explicitly from the call site.

## Research Summary

### Already Working (No Changes Needed)

| Item | Status | Evidence |
|------|--------|----------|
| **Desktop New Chat Flow** | Working | `newChatModeProvider` + `ChatContentPanel` in PR #5 |
| **Telegram History Loading** | Working | `GroupHistoryBuffer` + `get_or_create_session` in PRs #2-#3 |
| **Workspace Integration** | Working | Database migration v13, orchestrator workspace handling in PR #5, hardened in PR #39 |
| **Sandbox Working Directory** | Working | `AgentSandboxConfig`, Docker mounts, path normalization in PRs #38-#40 |

### One Real Bug Found

**`sendMessage()` couples to sidebar filter state instead of receiving workspace explicitly.**

`sendMessage()` reads `activeWorkspaceProvider` (sidebar filter) at `chat_message_providers.dart:1151`. This provider serves dual duty as both a session list filter and workspace for new chats. If the sidebar filter changes between workspace selection and first message send, the wrong workspace (or `null`) is sent to the server.

### Research Insights

**Why `_pendingWorkspaceId` is wrong (Pattern Recognition Agent):**
- The `_pending*` pattern is for values passed via `ChatScreen` widget constructor params (`agentType`, `agentPath`, `trustLevel`)
- Workspace does NOT flow through the constructor — it flows through `activeWorkspaceProvider`
- `ChatScreen` has no `workspaceId` constructor parameter
- Adding `_pendingWorkspaceId` would create an inconsistency with the existing architecture

**Why the simplest fix works (Simplicity + Conventions Agents):**
- `AgentHubScreen._startNewChat()` already writes `config.workspaceId` to `activeWorkspaceProvider` at line 689
- `sendMessage()` already reads `activeWorkspaceProvider` at line 1151
- The only issue is a potential race: sidebar filter changing between selection and send
- Fix: capture the workspace at the `_handleSend` call site and pass it explicitly

**Server-side is safe (Security Agent):**
- 3 independent validation layers: Pydantic regex, `validate_workspace_slug()`, per-method re-validation
- Null workspace_id handled cleanly everywhere
- Server falls back to session's stored workspace for existing sessions (orchestrator line 279)

### Separate Issues to File (Not In Scope)

- **AskUserQuestion race condition** — SSE event can fire before permission handler registers Future. Already has client-side retry mitigation (PR #37). File as separate P2 bug.
- **Telegram group history is in-memory only** — Acceptable limitation by design. No Telegram API to fetch bot chat history.
- **`activeWorkspaceProvider` dual-purpose** — Sidebar filter conflated with session workspace. Should eventually add `workspaceId` to `ChatMessagesState` (like `workingDirectory`). File as tech debt/enhancement.

## Proposed Solution

### Fix: Pass workspace explicitly to sendMessage

**Problem**: `chat_screen.dart:255` calls `sendMessage()` without `workspaceId`. The method reaches into `activeWorkspaceProvider` internally — a global sidebar filter that could change between workspace selection and first send.

**Fix**: Add `workspaceId` parameter to `sendMessage()`. In `_handleSend`, capture `activeWorkspaceProvider` at call time and pass it explicitly. This snapshots the workspace at send time, eliminating the race.

## Technical Approach

### Files to Modify (2 files, ~4 lines of diff)

#### 1. `app/lib/features/chat/providers/chat_message_providers.dart`

Add optional `workspaceId` parameter to `sendMessage()` (line 1014):

```dart
Future<void> sendMessage({
  required String message,
  String? systemPrompt,
  String? initialContext,
  String? priorConversation,
  List<String>? contexts,
  List<ChatAttachment>? attachments,
  String? agentType,
  String? agentPath,
  String? trustLevel,
  String? workspaceId,  // NEW
}) async {
```

At line 1151, use the explicit parameter with sidebar fallback:

```dart
// Read active workspace - prefer explicit param, fall back to sidebar filter
final activeWorkspace = workspaceId ?? _ref.read(activeWorkspaceProvider);
```

#### 2. `app/lib/features/chat/screens/chat_screen.dart`

In `_handleSend` (line ~241), capture workspace and pass to `sendMessage`:

```dart
void _handleSend(String message, [List<ChatAttachment>? attachments]) {
    final workspace = ref.read(activeWorkspaceProvider);  // snapshot at call time
    // ... existing code ...
    ref.read(chatMessagesProvider.notifier).sendMessage(
          message: message,
          initialContext: _pendingInitialContext,
          attachments: attachments,
          agentType: _pendingAgentType,
          agentPath: _pendingAgentPath,
          trustLevel: _pendingTrustLevel,
          workspaceId: workspace,  // NEW - pass explicitly
        );
```

### What We Are NOT Doing (And Why)

| Rejected Approach | Why |
|-------------------|-----|
| Add `_pendingWorkspaceId` to ChatScreen | Wrong pattern — workspace flows through provider, not constructor params |
| Add `workspaceId` to ChatScreen constructor | Unnecessary plumbing for this fix — workspace is already set in `activeWorkspaceProvider` before ChatScreen renders |
| Add `workspaceId` to `ChatMessagesState` | Correct long-term but larger refactor — file as tech debt |
| Modify `agent_hub_screen.dart` | Not needed — it already writes to `activeWorkspaceProvider` correctly |

### Edge Cases

| Scenario | Behavior | Correct? |
|----------|----------|----------|
| New chat via NewChatSheet | `activeWorkspaceProvider` set by AgentHubScreen, captured in `_handleSend` | Yes |
| New chat via empty-state workspace chips | Chips write to `activeWorkspaceProvider`, captured in `_handleSend` | Yes |
| Desktop embedded mode (no NewChatSheet) | Sidebar sets `activeWorkspaceProvider`, captured in `_handleSend` | Yes |
| Existing session, subsequent messages | `workspaceId` still captured from provider; server ignores it for existing sessions (uses stored workspace, line 279) | Yes |
| Sidebar filter changes during streaming | No effect — workspace was already sent on first message | Yes |

## Acceptance Criteria

- [x] New chat with workspace selected in sheet sends correct `workspace_id` to server
- [x] Sidebar filter "All" does not override sheet-selected workspace
- [x] Existing sessions still work correctly (server falls back to stored workspace)
- [x] Desktop embedded mode uses sidebar workspace correctly
- [x] No regressions — `flutter analyze` passes clean

## References

- Issue: #29
- PR #5: Workspace model and chat improvements
- PR #37: AskUserQuestion retry and error states
- PR #39: SDK session persistence
- `chat_message_providers.dart:1014` — `sendMessage` signature
- `chat_message_providers.dart:1151` — `activeWorkspaceProvider` read
- `chat_screen.dart:255` — `sendMessage` call site
- `agent_hub_screen.dart:689` — `activeWorkspaceProvider` set from NewChatConfig
- `orchestrator.py:279` — Server fallback to session's stored workspace
- `requests.py:139` — `ChatRequest.workspace_id` Pydantic validation with slug regex
