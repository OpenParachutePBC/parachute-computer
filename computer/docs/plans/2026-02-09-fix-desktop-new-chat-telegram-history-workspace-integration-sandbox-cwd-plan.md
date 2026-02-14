---
title: "Fix Desktop New Chat, Telegram History, Workspace Integration, Sandbox CWD"
type: fix
date: 2026-02-09
---

# Fix Desktop New Chat, Telegram History, Workspace Integration, Sandbox CWD

## Overview

Four issues blocking the workspace model feature from being usable end-to-end. Two are bugs (desktop new chat, telegram history), one is a missing integration (workspace picker in new chat), and one is a broken feature (sandbox working directory). Listed in implementation priority order.

---

## Issue 1: Desktop New Chat — Right Column Stays Empty

### Problem

In desktop/tablet two-column layout, clicking "New Chat" sets `currentSessionIdProvider` to `null`, but `ChatContentPanel` interprets `null` as "no session selected" and shows the "Select a conversation" placeholder. In mobile, `Navigator.push(ChatScreen())` bypasses this — so mobile works, desktop doesn't.

### Root Cause

`chat_content_panel.dart:17` — single null check can't distinguish "idle" from "new chat mode":

```dart
if (currentSessionId == null) {
  return _buildEmptyState(context);  // Always shows placeholder
}
```

### Solution

Add `newChatModeProvider` (`StateProvider<bool>`) to the provider chain. Update `ChatContentPanel` to check both providers.

### Changes

#### `app/lib/features/chat/providers/chat_session_actions.dart`

Add the new provider and update `newChatProvider` to set it:

```dart
/// Whether the user is actively composing a new chat (vs idle "no selection").
final newChatModeProvider = StateProvider<bool>((ref) => false);

final newChatProvider = Provider<void Function()>((ref) {
  return () {
    ref.read(currentSessionIdProvider.notifier).state = null;
    ref.read(chatMessagesProvider.notifier).clearSession();
    ref.read(newChatModeProvider.notifier).state = true;  // NEW
  };
});
```

Reset `newChatModeProvider` to `false` in `switchSessionProvider` (or wherever sessions are selected):

```dart
// In session selection logic:
ref.read(newChatModeProvider.notifier).state = false;
```

Also reset it in `sendMessage()` after the session is created (the first message creates the session, transitioning from "new chat" to "active session").

#### `app/lib/features/chat/widgets/chat_content_panel.dart`

Update the build method:

```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  final currentSessionId = ref.watch(currentSessionIdProvider);
  final isNewChat = ref.watch(newChatModeProvider);

  if (currentSessionId == null && !isNewChat) {
    return _buildEmptyState(context);
  }

  return const ChatScreen(embeddedMode: true);
}
```

#### Export the new provider

Add `newChatModeProvider` to the barrel export in `chat_providers.dart` (or wherever the chat providers are re-exported).

### Edge Cases

- **Click new chat twice** — Idempotent. `newChatProvider` sets null + true again.
- **Click session while in new chat mode** — `switchSession` resets `newChatModeProvider = false`, loads session.
- **Layout transition desktop → mobile** — `newChatModeProvider` persists. On mobile, session list is shown. If user taps a session, mode is cleared. If user taps "New Chat" on mobile, `Navigator.push(ChatScreen())` works as before.
- **Send first message in new chat mode** — Session is created, `currentSessionIdProvider` gets the new session ID, `newChatModeProvider` is reset to false. Panel continues showing the now-active session.

### Acceptance Criteria

- [x] Desktop/tablet: clicking "New Chat" shows ChatScreen with input field in right panel
- [x] Clicking an existing session from new chat mode loads that session
- [x] Sending a message from new chat mode creates a session and continues showing it
- [x] Mobile behavior unchanged (push navigation still works)

---

## Issue 2: Telegram Bot Loses All Message History

### Problem

Every Telegram message is treated as completely fresh — no context from prior messages. The bot creates a DB session (metadata), but no SDK JSONL transcript exists for it. The orchestrator sees "DB session exists but no transcript" and forces `is_new=True` every time.

### Root Cause

The session lifecycle has a disconnect:

1. Bot connector creates DB session with UUID placeholder ID (`base.py:197`)
2. First message → orchestrator finds DB session (`is_new=False`) but no SDK transcript
3. Orchestrator falls back to `is_new=True` (`orchestrator.py:610`)
4. SDK creates a new session, `finalize_session` replaces placeholder with SDK session ID
5. **Second message** → bot finds the finalized session via `get_session_by_bot_link`
6. Orchestrator checks for SDK transcript at the finalized session ID path
7. **If transcript path lookup fails** (e.g., cwd mismatch), falls back to `is_new=True` again

Additionally, a **concurrency bug**: the session lock is keyed on `session.id`, but `finalize_session` changes the session ID. Rapid messages can bypass the lock.

### Solution

Two fixes:

**Fix A — Ensure transcript is found on subsequent messages:**

The likely root cause is that `_check_sdk_session_exists` cannot find the transcript because the working directory used to compute the transcript path differs between calls. Verify that the working directory resolution for bot sessions is deterministic.

In `session_manager.py`, `_find_sdk_session_location` encodes the cwd into the transcript path. If the first message uses `vault_path` as cwd and finalization records a different path, the second message won't find the transcript.

**Fix B — Change concurrency lock key to chat_id:**

In `base.py`, change `_get_session_lock` to key on the Telegram chat ID (stable identifier) instead of the session ID (which changes during finalization):

```python
# base.py — BotConnector
async def _get_message_lock(self, chat_id: str) -> asyncio.Lock:
    """Get a per-chat lock (stable across session finalization)."""
    if chat_id not in self._chat_locks:
        self._chat_locks[chat_id] = asyncio.Lock()
    return self._chat_locks[chat_id]
```

Update `telegram.py` to use chat_id for locking instead of session.id.

### Changes

#### `computer/parachute/connectors/base.py`

- Rename `_session_locks` to `_chat_locks`, key on `chat_id` string
- Update `_get_session_lock` → `_get_chat_lock(chat_id)`

#### `computer/parachute/connectors/telegram.py`

- In `on_text_message`, acquire lock on `str(chat.id)` instead of `session.id`
- Same in `_cmd_journal` and any other handler that uses the session lock

#### `computer/parachute/core/orchestrator.py` (around line 598-610)

- Add debug logging for the transcript path being checked
- Log the cwd being used for path computation
- Verify that `finalize_session` stores the correct working directory

#### `computer/parachute/db/database.py`

- Verify `get_session_by_bot_link` excludes archived sessions (needed for `/new` command)
- If it doesn't filter archived sessions, add `AND archived = 0` to the query

### Investigation Steps (before coding)

1. Check `get_session_by_bot_link` query for archived filter
2. Add temporary debug logging to `_check_sdk_session_exists` to see what path it's checking
3. Send two Telegram messages and check server logs for session ID flow
4. Confirm whether `finalize_session` preserves bot link fields correctly

### Acceptance Criteria

- [x] Second Telegram message has context from the first message
- [x] `/new` command archives session and next message starts fresh
- [x] Two rapid messages don't create duplicate sessions
- [x] Server restart preserves Telegram session continuity

---

## Issue 3: Workspace Integration with New Chat Flow

### Problem

Workspaces exist in settings and the desktop sidebar but are disconnected from chat creation. The new chat flow has no workspace picker. Users can't select a workspace when starting a chat, and workspace defaults (trust, model, working dir) aren't applied.

### Design

**Auto-inherit + explicit picker:**
- When a workspace is active in the sidebar, new chats pre-fill its settings
- The new chat sheet also has a workspace picker for explicit selection
- Workspace settings (trust, model, working dir) are defaults — user can override toward MORE restrictive trust only (workspace trust is a floor)

### Changes

#### `app/lib/features/chat/widgets/new_chat_sheet.dart`

Add workspace picker as the first configuration option (before project folder):

```dart
// Workspace selection chips (similar to trust level chips)
// "None" + list of workspaces from workspacesProvider
// Selecting a workspace auto-fills trust, model, working dir
```

Add `workspaceId` field to `NewChatConfig`:

```dart
class NewChatConfig {
  final String? workspaceId;       // NEW
  final String? workingDirectory;
  final String? agentType;
  final String? agentPath;
  final String? trustLevel;
}
```

When a workspace is selected:
1. Fetch workspace config (already in `workspacesProvider`)
2. Set `trustLevel` from workspace (disable less-restrictive options in the trust picker)
3. Set `workingDirectory` from workspace (if set)
4. Set model from workspace (if set) — informational badge, not yet a picker

Pre-populate workspace from `activeWorkspaceProvider` on sheet open.

#### `app/lib/features/chat/screens/chat_screen.dart`

The inline empty state (where trust level chips are shown) needs the workspace picker too, for the desktop embedded flow where no sheet is used.

#### `app/lib/features/chat/providers/chat_message_providers.dart`

In `sendMessage()`, the workspace_id is already read from `activeWorkspaceProvider` (line 1150). Update to also accept it from `NewChatConfig.workspaceId` if set, with the config value taking priority.

#### Trust Level Floor UX

When a workspace is selected and its trust_level is e.g. "vault":
- Show "Full" chip as disabled/greyed out with tooltip "Workspace requires vault or higher"
- "Vault" and "Sandboxed" remain selectable
- If user deselects workspace, all trust levels become available again

### Edge Cases

- **Override trust to less restrictive** — UI prevents it (chips disabled). Server also enforces as a floor.
- **Delete workspace with active sessions** — Already handled: `DELETE /api/workspaces/{slug}` sets `workspace_id = NULL` on linked sessions (`api/workspaces.py:74-78`).
- **Workspace selected + manual working dir override** — Manual override takes priority (matches existing behavior where explicit params override workspace defaults).
- **Workspace model shown but not changeable** — Model is informational in the new chat sheet. The actual model used comes from workspace config → server. Future: add model picker.

### Acceptance Criteria

- [x] New chat sheet shows workspace picker with available workspaces
- [x] Selecting workspace auto-fills trust level and working directory
- [x] Active sidebar workspace pre-fills in new chat sheet
- [x] Trust levels less restrictive than workspace floor are disabled
- [x] Chat created with workspace has correct `workspace_id` on the session
- [x] Workspace defaults can be overridden (toward more restrictive trust)

---

## Issue 4: Sandbox Working Directory Not Working

### Problem

When a user selects a working directory and sandboxed trust level, the Docker container doesn't mount the directory and doesn't know what CWD to use. The agent reports an empty workspace.

### Root Cause (3 compounding problems)

1. Working directory not added to `AgentSandboxConfig.allowed_paths`
2. No CWD forwarded to Docker container (no env var, no `--workdir`)
3. Container entrypoint doesn't handle CWD

### Changes

#### `computer/parachute/core/orchestrator.py` (around line 632-645)

When building `AgentSandboxConfig`, auto-add the effective working directory to `allowed_paths`:

```python
sandbox_config = AgentSandboxConfig(
    session_id=sandbox_sid,
    agent_type=agent.type.value if agent.type else "chat",
    allowed_paths=session.permissions.allowed_paths,
    network_enabled=True,
    mcp_servers=resolved_mcps,
    working_directory=effective_working_dir,  # NEW
)

# Auto-add working directory to allowed_paths
if effective_working_dir:
    relative_wd = self.session_manager.make_working_directory_relative(
        effective_working_dir, self.vault_path
    )
    if relative_wd and relative_wd not in sandbox_config.allowed_paths:
        sandbox_config.allowed_paths.append(relative_wd)
```

#### `computer/parachute/core/sandbox.py`

Add `working_directory` to `AgentSandboxConfig`:

```python
@dataclass
class AgentSandboxConfig:
    session_id: str
    agent_type: str = "chat"
    allowed_paths: list[str] = field(default_factory=list)
    network_enabled: bool = False
    timeout_seconds: int = 300
    mcp_servers: Optional[dict] = None
    working_directory: Optional[str] = None  # NEW: vault-relative path
```

In `_build_run_args()`, pass the working directory as an environment variable:

```python
if config.working_directory:
    args.extend(["-e", f"PARACHUTE_CWD=/vault/{config.working_directory}"])
```

#### `computer/parachute/docker/entrypoint.py`

Read `PARACHUTE_CWD` and set the working directory:

```python
import os

cwd = os.environ.get("PARACHUTE_CWD")
if cwd and os.path.isdir(cwd):
    os.chdir(cwd)
```

#### Path validation — reject outside-vault paths

In `session_manager.py` `resolve_working_directory`, reject paths that resolve outside the vault:

```python
resolved = (vault_path / working_directory).resolve()
if not str(resolved).startswith(str(vault_path.resolve())):
    logger.warning(f"Working directory escapes vault: {working_directory}")
    return str(vault_path)  # fallback to vault root
```

### Edge Cases

- **No working dir + sandboxed** — Entire vault mounted read-only, no CWD set. Default behavior.
- **Working dir outside vault** — Rejected by path validation, falls back to vault root.
- **Working dir doesn't exist** — `_build_mounts` skips nonexistent paths, vault mounted read-only. Consider emitting a warning event to the client.
- **Docker unavailable** — Existing fallback to vault trust with warning event.

### Acceptance Criteria

- [x] Sandboxed session with working directory: agent can see and list files
- [x] Working directory mounted read-write inside container
- [x] Container CWD set to the mounted working directory
- [x] Paths outside vault rejected
- [x] Non-existent working directory falls back gracefully

---

## Implementation Order

```
1. Desktop new chat bug     (~30 min)  — app/ only, 3 files
2. Telegram history bug     (~1-2 hrs) — computer/ only, 4 files, needs investigation
3. Workspace integration    (~2-3 hrs) — app/ only, 4 files, UI work
4. Sandbox working dir      (~1-2 hrs) — computer/ only, 4 files
```

Issues 1 and 2 are independent and can be worked in parallel. Issue 3 builds on Issue 1 (needs new chat mode working in desktop). Issue 4 is fully independent.

## References

- Brainstorm: `docs/brainstorms/2026-02-09-workspace-integration-and-bugs-brainstorm.md`
- Existing sandbox plan: `docs/plans/2026-02-08-fix-sandbox-session-persistence-plan.md`
- Workspace model plan: `docs/plans/2026-02-08-feat-workspace-model-plugin-loading-chat-ui-plan.md`
