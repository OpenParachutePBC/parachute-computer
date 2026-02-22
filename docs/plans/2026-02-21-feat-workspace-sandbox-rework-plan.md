---
title: "feat: Workspace & sandbox rework — sandboxed-by-default, scratch dirs, workspace UI"
type: feat
date: 2026-02-21
issue: 62
deepened: 2026-02-21
final-review: 2026-02-21
---

# Workspace & Sandbox Rework

## Enhancement Summary

**Deepened on:** 2026-02-21
**Final review:** 2026-02-21 (9 agents: python-reviewer, performance-oracle, code-simplicity-reviewer, flutter-reviewer, architecture-strategist, parachute-conventions-reviewer, security-sentinel, pattern-recognition-specialist, docker-best-practices-researcher)

### Key Improvements from Review
1. **Critical bug caught:** `_default` slug fails validation regex — use dedicated `run_default()` method
2. **Security fix:** Docker fallback must NOT apply to bot sessions — external users get hard-fail, not bare metal
3. **Consolidation:** Extract single `normalize_trust_level()` to replace 5-6 duplicate legacy maps
4. **Docker hardening:** `--read-only` root FS, `--tmpfs /scratch:size=512m`, `--memory-reservation`, ulimits, user-defined bridge network
5. **Scope reduction:** 8 chunks → 5. Cut bot default workspace (YAGNI), defer quick-create, split session archiving to separate PR
6. **Flutter insight:** Session archiving UI is already 90% implemented — only snackbar-undo missing
7. **Vault access for casual chats:** Mount vault read-only in default container
8. **Data integrity:** Record `effective_execution_mode` on session when Docker fallback triggers
9. **Migration safety:** v16 needs `schema_version` guard + v14 compatibility marking
10. **MCP simplification:** Flat default list for v1, no overlay merge semantics
11. **Scratch dir isolation is organizational, not security** — same UID, accepted trade-off for v1

---

## Overview

Rework how workspaces, chats, and sandboxing relate to each other. The core change: **sandboxed execution becomes the default for all chats**, with workspaces as optional project contexts — not prerequisites for safe code execution. Includes trust level rename, a shared default sandbox container, per-session scratch directories, server-default MCP config, session archiving, and workspace UI improvements.

## Problem Statement

The current system ties sandboxed execution to workspaces. Starting a casual chat either requires a workspace (for sandboxing) or runs on bare metal (unsafe for code execution). The trust level naming (`trusted`/`untrusted`) makes the sandboxed default feel second-class. Workspaces are buried in Settings. Casual chats land in `/workspace` staring at `entrypoint.py`.

## Proposed Solution

Five implementation chunks, ordered by dependency:

1. **Rename trust levels** — `untrusted` → `sandboxed`, `trusted` → `direct`
2. **Default sandbox container** — always-running shared container for casual chats
3. **Per-session scratch dirs** — `/scratch/{session_id}/` in every container
4. **Server-default MCP config** — casual chats get MCPs without a workspace
5. **Workspace-aware chat UI** — workspace switcher in chat tab

**Separate PR:** Session archiving snackbar-undo (only missing piece — backend + Flutter UI already 90% done).
**Deferred:** Workspace quick-create from New Chat (convenience layer), bot default workspace in `bots.yaml` (YAGNI — no user request).

## Technical Approach

### Phase 1: Foundation (Chunks 1–3)

These are tightly coupled and form the base everything else builds on.

#### Chunk 1: Trust Level Rename

Rename `untrusted` → `sandboxed`, `trusted` → `direct` across server and app. Legacy values continue to be accepted.

**Step 0: Consolidate legacy maps.** Before renaming anything, extract a single canonical normalization function. Currently there are 5-6 duplicate legacy-mapping dicts across `models/session.py`, `capability_filter.py`, `connectors/config.py`, `orchestrator.py`, and `api/sessions.py`. Consolidate first:

```python
# core/trust.py (NEW FILE — single source of truth)
from typing import Literal

TrustLevelStr = Literal["direct", "sandboxed"]

_NORMALIZE_MAP = {
    # New canonical values
    "direct": "direct",
    "sandboxed": "sandboxed",
    # Legacy values (accepted indefinitely)
    "trusted": "direct",
    "untrusted": "sandboxed",
    "full": "direct",
    "vault": "direct",
}

def normalize_trust_level(value: str) -> TrustLevelStr:
    """Normalize any trust level string to canonical form.

    Raises ValueError for unrecognized values (not silent passthrough).
    """
    normalized = _NORMALIZE_MAP.get(value.lower())
    if normalized is None:
        raise ValueError(
            f"Unknown trust level: {value!r}. "
            f"Valid values: {', '.join(sorted(_NORMALIZE_MAP.keys()))}"
        )
    return normalized
```

Then update all 5-6 call sites to `from parachute.core.trust import normalize_trust_level`.

**Backend changes:**

| File | Change |
|------|--------|
| `core/trust.py` | **NEW** — canonical `normalize_trust_level()`, `TrustLevelStr` |
| `models/session.py:14-22` | Rename `TrustLevel.TRUSTED` → `DIRECT`, `TrustLevel.UNTRUSTED` → `SANDBOXED` |
| `models/workspace.py:13` | Import `TrustLevelStr` from `core/trust` |
| `connectors/config.py:14` | Import `TrustLevelStr` from `core/trust`, add Pydantic validator using `normalize_trust_level` |
| `core/capability_filter.py:20-31` | Update `TRUST_ORDER` dict, import from `core/trust` |
| `core/orchestrator.py:54+` | All `TrustLevel.TRUSTED`/`UNTRUSTED` references |
| `core/sandbox.py` | Docstrings and trust checks |
| `api/sessions.py:176-214` | Use `normalize_trust_level` in `SessionConfigUpdate` validator |
| `api/bots.py` | Trust level references in bot config endpoints |
| `api/chat.py:60,89` | Trust level logging |
| `connectors/base.py:117-128` | Parameter names and defaults |
| `db/database.py` | New migration v16 (see below) |

**Flutter changes** (comprehensive list from flutter-reviewer, 18 findings):

**Key principle:** Replace all raw string comparisons on `trustLevel` with typed `TrustLevel` comparisons. Add a `parsedTrustLevel` getter on `ChatSession` to centralize legacy mapping:

```dart
// chat/models/chat_session.dart
TrustLevel get parsedTrustLevel => TrustLevel.fromString(trustLevel);
```

**Important:** `TrustLevel.fromString(null)` must continue returning `TrustLevel.direct` (not `sandboxed`). The default-to-sandboxed for new casual chats is a **server-side** change. If the client defaulted null to sandboxed, it would incorrectly render pre-rename sessions that have null trust levels.

| File | Change |
|------|--------|
| `settings/models/trust_level.dart:7-9` | Rename enum values (`trusted`→`direct`, `untrusted`→`sandboxed`), update `fromString()` legacy map |
| `settings/widgets/trust_levels_section.dart` | Update labels: "Sandboxed" (default), "Direct" (escape hatch) |
| `settings/widgets/trust_levels_section.dart:160` | Footer: "Docker required for Sandboxed sessions" |
| `chat/models/chat_session.dart:111` | **NEW** `TrustLevel get parsedTrustLevel` getter |
| `chat/widgets/session_config_sheet.dart:49` | Replace hardcoded `_trustLevels = ['trusted', 'untrusted']` with `TrustLevel.values.map((e) => e.name).toList()` |
| `chat/widgets/session_config_sheet.dart:336` | Replace `== 'untrusted'` with typed `TrustLevel.fromString(_trustLevel) == TrustLevel.sandboxed` |
| `chat/widgets/session_list_item.dart:141` | Replace `!= 'trusted'` with typed comparison via `parsedTrustLevel` |
| `chat/screens/chat_hub_screen.dart:200` | Change `TrustLevel.untrusted` → `TrustLevel.sandboxed` in approval dialog |

**DB migration v16** — idempotent rename with `schema_version` guard (matching existing v14/v15 pattern):

```python
# In db/database.py — _run_migrations()
async with self._connection.execute(
    "SELECT version FROM schema_version WHERE version = 16"
) as cursor:
    row = await cursor.fetchone()
if not row:
    # Rename trust levels to new canonical values
    await self._connection.execute(
        "UPDATE sessions SET trust_level = 'sandboxed' WHERE trust_level = 'untrusted'"
    )
    await self._connection.execute(
        "UPDATE sessions SET trust_level = 'direct' WHERE trust_level IN ('trusted', 'full', 'vault')"
    )
    await self._connection.execute(
        "UPDATE pairing_requests SET approved_trust_level = 'sandboxed' "
        "WHERE approved_trust_level = 'untrusted'"
    )
    await self._connection.execute(
        "UPDATE pairing_requests SET approved_trust_level = 'direct' "
        "WHERE approved_trust_level IN ('trusted', 'full', 'vault')"
    )
    # Mark v16 as applied
    await self._connection.execute(
        "INSERT OR IGNORE INTO schema_version (version, applied_at) "
        "VALUES (16, datetime('now'))"
    )
    # Also mark v14 as applied to prevent it from re-running and reverting
    # v14 mapped sandboxed→untrusted, which would undo our rename
    await self._connection.execute(
        "INSERT OR IGNORE INTO schema_version (version, applied_at) "
        "VALUES (14, datetime('now'))"
    )
    await self._connection.commit()
```

**v14/v16 interaction (caught by conventions reviewer):** The v14 migration maps `sandboxed` → `untrusted`. If v14 somehow runs after v16 (e.g., downgrade scenario), it would revert the rename. Marking v14 as applied when v16 runs prevents this.

**Note on `vault` → `direct`:** The security sentinel flagged that the old `vault` level was directory-restricted, while `direct` is unrestricted. However, `vault` was already mapped to `trusted` (unrestricted bare metal) in the v14 migration. No sessions currently have `trust_level='vault'`. The migration is safe.

**Default trust level change**: Casual (workspace-less) chats now default to `sandboxed` instead of `direct`. This is the key behavioral change — see Docker fallback below.

**Documentation:** Update `computer/CLAUDE.md` (line 41, 81-85) and `app/CLAUDE.md` (line 76) to reflect the new trust model.

#### Chunk 2: Default Sandbox Container

An always-running shared container for casual chats.

**Container name: `parachute-default`** (not `parachute-ws-_default`).

> **Critical fix:** The original plan used `_default` as a workspace slug passed to `run_persistent()`. This crashes at runtime — `validate_workspace_slug()` regex (`^[a-z0-9][a-z0-9-]*[a-z0-9]$`) rejects underscores. **7 of 10 review agents flagged this.**
>
> **Solution:** Add a dedicated `run_default()` method on `DockerSandbox` that manages the default container separately from workspace containers. This avoids overloading workspace slug validation and makes the default container a first-class concept, not a special-cased workspace.

**Container spec:**
- Image: `parachute-sandbox:latest` (same as workspace containers)
- Name: `parachute-default`
- Labels: `app=parachute`, `type=default-sandbox`
- CMD: `sleep infinity` (persistent mode, same as workspace containers)
- Init: `--init` (tini for zombie reaping)
- Resources: `1.5g` memory (with `--memory-reservation 512m`), `2.0` CPU
- Network: user-defined bridge `parachute-sandbox` (not `--internal` — SDK needs internet for Anthropic API; provides DNS isolation from other Docker containers)
- Security: `--cap-drop ALL`, `--no-new-privileges`, `--pids-limit 200`, `--read-only`
- Ulimits: `--ulimit nofile=1024:2048`, `--ulimit nproc=256:512`
- Filesystem: `--tmpfs /tmp:size=256m`, `--tmpfs /scratch:size=512m,mode=1700`, `--tmpfs /run:size=64m`
- Mounts:
  - `{vault}/.parachute/sandbox/default/.claude` → `/home/sandbox/.claude:rw` (transcript persistence)
  - `{vault}` → `/vault:ro` (read-only vault access for casual chats)
  - `--add-host host.docker.internal:host-gateway` (cross-platform host access for MCP — required on Linux, no-op on macOS)

**Research insights on container hardening:**
- `--read-only` root filesystem prevents writes to the container image layer. Combined with targeted `--tmpfs` mounts for `/tmp`, `/scratch`, and `/run`, this provides strong filesystem isolation while allowing necessary writes.
- `--tmpfs /scratch:size=512m,mode=1700` bounds scratch disk usage, is RAM-backed (fast), and auto-cleans on container restart. The sticky bit (1700) prevents users from deleting each other's directories.
- `--memory-reservation 512m` is a soft limit that lets Docker reclaim memory under host pressure without hard-killing the container. The hard limit of `1.5g` allows ~5 concurrent sessions at ~200-300MB each.
- `--add-host host.docker.internal:host-gateway` is required on Linux for containers to reach host services. No-op on macOS (Docker Desktop provides it automatically).
- Do NOT use `--noexec` on `/scratch` — agents need to execute generated scripts there.

**Vault read-only mount (agent-native fix):**
The original plan had no vault mount for the default container. The agent-native reviewer flagged that this makes casual chats unable to read any user files — a significant capability gap. Mounting the vault read-only gives agents the same read visibility as the user while maintaining the security boundary (no writes to the vault from casual chats).

**Lifecycle:**
- Created lazily on first casual sandboxed message via new `ensure_default_container()` method
- Reused across all casual sessions via `docker exec`
- Stopped and removed on `parachute server stop`
- Recreated on OOM (exit code 137) — with exponential backoff if OOM recurs 3 times in 5 minutes
- `reconcile()` at server startup discovers it via `type=default-sandbox` label (not the `parachute-ws-*` name pattern)

**Implementation — new method on DockerSandbox:**
```python
async def run_default(self, session_id: str, ...) -> AsyncIterator[dict]:
    """Run a session in the shared default sandbox container.

    Unlike run_persistent() which takes a workspace slug,
    this manages the dedicated default container directly.
    """
    container_name = "parachute-default"
    await self._ensure_default_container()
    # ... docker exec with session-scoped env vars
```

**Routing change in orchestrator:**
```python
if trust_level == TrustLevel.SANDBOXED:
    if workspace_id:
        await sandbox.run_persistent(workspace_id, ...)
    else:
        await sandbox.run_default(session_id, ...)
```

**Docker fallback — differentiated by session source:**

> **Security fix:** 6 of 10 agents flagged that the original fallback (silent downgrade to bare metal) is dangerous for bot sessions. External Telegram/Discord/Matrix users would get full host access if Docker goes down.

| Session source | Docker unavailable behavior |
|---|---|
| **App (local user)** | Fall back to direct mode with warning. Preserves zero-config onboarding. |
| **Bot connector (external user)** | Hard fail with error message. External users must never get bare metal access. |

```python
# orchestrator.py — differentiated fallback
if trust_level == TrustLevel.SANDBOXED:
    if self._sandbox and self._sandbox.available:
        effective_mode = "sandboxed"
        # ... run in container
    elif session_source == "app":
        effective_mode = "direct"
        logger.warning("Docker unavailable, falling back to direct execution")
        yield {"type": "warning", "message": "Docker unavailable — running without sandbox."}
        # ... fall through to direct execution
    else:
        # Bot/external sessions: hard fail
        yield {"type": "error", "error": "Docker required for external sessions."}
        return
```

**Record `effective_execution_mode` on session (architecture reviewer, 88% confidence):** When Docker fallback triggers, the session record says `trust_level=sandboxed` but execution was `direct`. Without tracking this, downstream consumers (UI, audit, MCP filtering) can't distinguish the two. The security model inverts: the agent has full host access but gets sandboxed-tier MCP access (restricted). Fix: record `effective_execution_mode` in session metadata so MCP capability filtering uses the *actual* execution environment, not the *requested* trust level.

**System prompt must be built AFTER Docker resolution.** The current orchestrator builds the system prompt before the trust level check. If falling back to direct mode, the prompt may reference scratch directories that don't exist. Move scratch dir prompt injection to after the execution mode is resolved.

**Pre-exec process guard:**
Before each `docker exec` in the default container, check the number of running processes. If near the `--pids-limit` (200), reject gracefully instead of OOM-killing all active sessions:
```python
# Quick process count check before exec
result = await docker_exec(container_name, "ps aux | wc -l")
if int(result.strip()) > 150:
    yield {"type": "error", "error": "Sandbox busy, please try again shortly."}
    return
```

#### Chunk 3: Per-Session Scratch Dirs

Every sandboxed session gets `/scratch/{session_id}/` inside its container.

**Entrypoint changes** (`docker/entrypoint.py`):

```python
import re

# After reading stdin JSON, before running SDK query
session_id = os.environ.get("PARACHUTE_SESSION_ID", "")

# Defense-in-depth: validate session_id format at the trust boundary
if session_id and not re.match(r'^[a-zA-Z0-9_-]+$', session_id):
    emit({"type": "error", "error": "Invalid session ID format"})
    sys.exit(1)

scratch_dir = f"/scratch/{session_id}" if session_id else "/scratch/default"
os.makedirs(scratch_dir, mode=0o700, exist_ok=True)

# For casual chats (no PARACHUTE_CWD), use scratch as cwd
cwd = os.environ.get("PARACHUTE_CWD")
if cwd and os.path.isdir(cwd):
    os.chdir(cwd)
else:
    os.chdir(scratch_dir)
```

Note: `PARACHUTE_SCRATCH_DIR` env var is not needed — the agent can simply use `pwd` to discover its working directory. The system prompt mentions the scratch dir only for workspace sessions (where cwd is the project dir, not the scratch dir).

**System prompt addition** — the orchestrator appends to the system prompt AFTER execution mode is resolved:
- **Casual sandboxed chats:** `Your working directory is your private scratch space. Files here are temporary.`
- **Workspace sandboxed chats:** `Your project directory is {working_directory}. You also have a private scratch space at /scratch/{session_id}/ for temporary files.`
- **Direct (bare metal) sessions:** No scratch dir mention. Full host access.

**Scratch dir lifecycle:**
- Created by entrypoint on each `docker exec`
- Backed by `--tmpfs /scratch:size=512m` — RAM-backed, bounded at 512MB total across all sessions, auto-cleaned on container restart
- No proactive cleanup needed — tmpfs handles it
- If a long-running container accumulates many stale scratch dirs, they're bounded by the 512MB tmpfs limit

**Direct (bare metal) sessions:** No scratch dir. Direct sessions have full host access and can use any directory.

### Phase 2: MCP & Workspace UI (Chunks 4–5)

#### Chunk 4: Server-Default MCP Config

Casual chats get default MCPs without needing a workspace.

**Config approach** — add a flat list of default MCP names to `config.yaml`. Reuse the existing `WorkspaceCapabilities` model for type validation:

```yaml
# config.yaml
default_capabilities:
  mcps:
    - parachute    # Built-in Parachute MCP (journal search, chat search, etc.)
  skills: "all"
  agents: "all"
```

**Implementation:**

| File | Change |
|------|--------|
| `config.py` | Add `default_capabilities: Optional[WorkspaceCapabilities]` to `Settings` (typed, not raw dict) |
| `core/orchestrator.py:240-300` | Load default capabilities when `workspace_id` is null |
| `core/capability_filter.py` | Simple if/else: workspace uses existing filter, no-workspace gets default list |

**Simplified MCP loading for v1 (per simplicity reviewer, 88% confidence):**

No overlay/merge semantics. Simple two-path logic:

```python
# orchestrator.py — capability resolution
if workspace_id:
    # Existing path: workspace capabilities filter (unchanged)
    capabilities = filter_capabilities(discovered, workspace_config)
else:
    # New path: server default capabilities
    capabilities = filter_capabilities(discovered, settings.default_capabilities)
```

Workspaces already have their own capability filtering via `_filter_by_set()`. The default capabilities use the exact same filter. No new merge logic, no overlay system. If a workspace wants to extend defaults, it lists the MCPs it needs — same as today.

**MCP network access:** The built-in `parachute` MCP is an stdio server (command + args) spawned by the SDK inside the container. It does NOT need HTTP access to `localhost:3333`. User-configured HTTP MCPs in `default_capabilities` would need `host.docker.internal` — already handled by the `--add-host` flag in Chunk 2.

**Cache improvement:** The MCP config cache currently has no file-change detection. Adding a `stat()` mtime check per message (~0.05ms) avoids requiring a server restart when `.mcp.json` or `config.yaml` changes.

#### Chunk 5: Workspace-Aware Chat UI

Move workspace management from Settings into the chat tab.

**Workspace switcher** — extract as its own widget class (`WorkspaceChipRow`). `ChatHubScreen` is already 735 lines — adding the chip row inline would violate the "extract widget classes, not helper methods" convention.

```
[ All ] [ parachute-computer ] [ client-project ] [ + ]
```

- "All" shows all active sessions regardless of workspace
- Workspace names only (no session counts in v1 — simplicity reviewer recommends deferring counts)
- "+" chip navigates to workspace creation in Settings (full quick-create deferred)
- Selected chip is visually highlighted
- Workspace-less sessions appear in "All" but not under any workspace filter

**Implementation:**

| File | Change |
|------|--------|
| `chat/widgets/workspace_chip_row.dart` | **NEW** — `ConsumerWidget` that watches `workspacesProvider` and `activeWorkspaceProvider` |
| `chat/screens/chat_hub_screen.dart` | Add `WorkspaceChipRow` below app bar |
| `chat/providers/workspace_providers.dart` | Persist `activeWorkspaceProvider` via SharedPreferences (use `StateNotifier`, not plain `StateProvider`) |
| `chat/providers/chat_session_providers.dart` | Filter by `activeWorkspaceProvider` — client-side filtering from cached session list, NOT per-workspace API calls |
| `chat/widgets/session_list_panel.dart` | Respect workspace filter in all views (active, archived, search) |

**Client-side filtering (performance reviewer, 91% confidence):**

Workspace session filtering should derive from the already-fetched session list. `chatSessionsProvider` loads sessions with `workspaceId` fields. A synchronous `Provider` that filters the cached list avoids N+1 HTTP requests on every chip tap:

```dart
final workspaceSessionsProvider = Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeWorkspaceProvider);
  final sessionsAsync = ref.watch(chatSessionsProvider);

  if (activeSlug == null) return sessionsAsync;  // "All" — pass through

  return sessionsAsync.whenData(
    (sessions) => sessions.where((s) => s.workspaceId == activeSlug).toList(),
  );
});
```

Same pattern for session counts if added later — derive from cached data, never N+1 API calls.

**Workspace filter behavior:**
- Filter applies to active, archived, and search views
- Workspace-less sessions only appear in "All"
- Active streams remain accessible regardless of filter (badge/indicator if filtered out)
- Switching workspace filter also updates New Chat sheet default (already wired via `activeWorkspaceProvider`)

**Sessions with deleted workspaces:** Sessions keep their `workspace_id` string but appear only in "All" view (workspace no longer exists as a filter option). No cascade delete.

**Provider consolidation:** All three session list providers (`chatSessionsProvider`, `archivedSessionsProvider`, `searchedSessionsProvider`) need workspace filter propagation. Consider a single `filteredSessionsProvider` that wraps the active workspace filter and delegates to the appropriate data source.

---

## Separate PR: Session Archiving Snackbar

Session archiving is already 90% implemented (verified by flutter reviewer, 92% confidence):
- `Dismissible` swipe actions in `session_list_item.dart` ✅
- `archivedSessionsProvider` in `chat_session_providers.dart` ✅
- `archiveSession()`/`unarchiveSession()` service methods ✅
- Archive toggle button in `ChatHubScreen` app bar ✅
- Backend `archived` column, API endpoints, orchestrator delegates ✅

**Only remaining work:**
- Wire `onArchive` callback from `ChatHubScreen` to show snackbar with 5-second undo
- Fix `get_session_by_bot_link` to find archived sessions (currently filters `WHERE archived = 0`, causing duplicate session creation instead of unarchive)

This is a small, self-contained change unrelated to the sandbox rework. Ship as its own PR.

---

## Deferred Work

### Workspace Quick-Create (was Chunk 7)
Create workspace from New Chat sheet. Deferred because Chunk 5 already solves "workspaces buried in Settings" by putting the switcher in the chat tab. Users can still create workspaces in Settings. Add inline creation later if demand appears.

### Bot Default Workspace (was Chunk 8)
Configurable `default_workspace` per platform in `bots.yaml`. Deferred because no user has requested this (YAGNI, 95% confidence from simplicity reviewer) and bot sessions work fine without workspaces today. If needed, users can `PATCH` a session's `workspace_id` after creation.

---

## Acceptance Criteria

### Functional Requirements

- [ ] Trust levels renamed to `sandboxed`/`direct` throughout server and app
- [ ] Legacy trust values (`trusted`, `untrusted`, `full`, `vault`) accepted via single `normalize_trust_level()` function
- [ ] DB migration v16 converts existing trust level values (with `schema_version` guard and v14 compat)
- [ ] CLAUDE.md docs updated for new trust model
- [ ] Casual chats default to sandboxed execution in the `parachute-default` container
- [ ] Default container has `--read-only` root FS, `--tmpfs` scratch, vault read-only mount, ulimits
- [ ] App-local sessions: graceful fallback to direct when Docker unavailable (with warning)
- [ ] Bot sessions: hard fail when Docker unavailable (no bare metal for external users)
- [ ] `effective_execution_mode` recorded on session when Docker fallback triggers
- [ ] Every sandboxed session gets a `/scratch/{session_id}/` directory with session_id validation
- [ ] Casual chats start in their scratch dir (not `/workspace`)
- [ ] Workspace chats start in their working directory with scratch dir available
- [ ] System prompt reflects actual execution environment (built after Docker resolution)
- [ ] Server-default MCP config provides tools to casual chats (flat default list, reusing `WorkspaceCapabilities` model)
- [ ] Workspace switcher chip row in chat tab (extracted `WorkspaceChipRow` widget)
- [ ] Workspace filter applies to active, archived, and search views (client-side filtering)

### Non-Functional Requirements

- [ ] `parachute-default` container warm start < 200ms for `docker exec`
- [ ] Pre-exec process count guard prevents OOM cascade
- [ ] No regression for users without Docker (app sessions fall back, bot sessions fail safely)
- [ ] App handles server version skew gracefully (404 on missing endpoints doesn't crash)
- [ ] Trust level rename is backward-compatible (old API values still work)
- [ ] MCP config cache refreshes on file mtime change without server restart
- [ ] Container uses user-defined bridge network for DNS isolation

## Dependencies & Prerequisites

- **Completed:** PR #38 (persistent containers), PR #39 (sandbox session persistence), PR #42 (bot management UX)
- **Related:** #47 (MCP context injection) — server-default MCP config is a subset of this work
- **Related:** #35 (multi-agent workspace teams) — workspace-as-team-boundary builds on all decisions here
- **Related:** #69 (rich sandbox image) — container pooling by config hash could eventually apply to default container

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| Docker required for basic chat | High — breaks zero-config onboarding | Differentiated fallback: app users → direct with warning; bot users → hard fail |
| Trust level rename breaks existing configs | Medium — `bots.yaml`, workspace configs | Single `normalize_trust_level()` accepts all legacy values; Pydantic validators use it |
| Default container OOM under concurrent load | Medium — kills all casual sessions | 1.5g hard limit + 512m reservation; pre-exec process guard; exponential backoff on repeat OOM |
| Scratch dir isolation is organizational, not security | Medium — same UID owns all scratch dirs | **Accepted trade-off for v1.** All `docker exec` runs as `sandbox` user. `0o700` provides organizational separation but any session can access another's scratch dir. Acceptable for single-user local product. Future: gVisor or per-session containers for real isolation. |
| Scratch dir disk usage | Low — bounded by tmpfs | `--tmpfs /scratch:size=512m` auto-cleans on restart, hard-bounds at 512MB |
| App-server version skew | Low — cosmetic issues only | App handles 404 gracefully; trust level legacy layer |
| `reconcile()` missing default container | Medium — orphaned on restart | Discover via `type=default-sandbox` label, not name pattern |
| Shared `.claude` transcript mount | Medium — cross-session transcript access | Acceptable for v1 (all casual sessions are from the same local user). Revisit for multi-user. |
| Docker fallback data model dishonesty | Medium — session says `sandboxed` but ran `direct` | Record `effective_execution_mode`; use effective mode for MCP capability filtering |

## References

### Internal
- Issue #62 brainstorm: workspace & chat organization rethink
- Issue #47: MCP session context injection
- Issue #35: multi-agent workspace teams
- Issue #69: rich sandbox image with efficient storage
- `computer/parachute/core/sandbox.py` — Docker sandbox implementation
- `computer/parachute/core/orchestrator.py` — session routing logic
- `computer/parachute/docker/entrypoint.py` — container entrypoint
- `computer/parachute/docker/Dockerfile.sandbox` — container image
- `computer/parachute/models/session.py` — TrustLevel enum
- `computer/parachute/core/capability_filter.py` — trust-based capability filtering
- `computer/parachute/core/validation.py` — workspace slug validation regex
- `app/lib/features/settings/models/trust_level.dart` — Flutter trust level enum
- `app/lib/features/chat/screens/chat_hub_screen.dart` — main chat screen (735 lines)
- `app/lib/features/chat/widgets/new_chat_sheet.dart` — new chat creation (638 lines)

### Patterns from Prior Work
- Container pooling by config hash (rich sandbox brainstorm #69)
- Three-tier resume fallback: SDK resume → history injection → fresh (PR #39)
- Symlink-aware transcript discovery (PR #39 security hardening)
- Docker labels for container discovery and reconciliation (PR #38)
- Tini as PID 1 for zombie prevention (PR #38)

### Docker Best Practices Applied
- `--read-only` root filesystem with targeted tmpfs mounts (OWASP recommendation)
- `--tmpfs /scratch:size=512m,mode=1700` for bounded, RAM-backed scratch space
- `--memory-reservation` soft limit for graceful memory pressure handling
- `--ulimit nofile=1024:2048` and `--ulimit nproc=256:512` for resource bounding
- User-defined bridge network `parachute-sandbox` for DNS isolation from other Docker containers
- `--add-host host.docker.internal:host-gateway` for cross-platform host access (required on Linux)
- Default seccomp profile retained (blocks ~44 dangerous syscalls)
- gVisor (`--runtime=runsc`) identified as upgrade path for escalated threat models
- Do NOT use `--noexec` on `/scratch` — agents must execute generated scripts there

### Isolation Upgrade Path
| Level | When | Approach |
|-------|------|----------|
| Docker (v1, this plan) | Single user, local | Hardened Docker with `--cap-drop ALL`, `--no-new-privileges`, `--read-only`, `--pids-limit` |
| gVisor (v2) | Multi-user or cloud | Drop-in runtime change (`--runtime=runsc`), same Docker CLI, ~10-30% I/O overhead |
| Firecracker (v3) | Fully untrusted agents | MicroVMs with KVM hardware isolation, ~125ms boot |
