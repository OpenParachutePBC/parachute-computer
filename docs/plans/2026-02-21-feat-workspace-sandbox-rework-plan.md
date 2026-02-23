---
title: "feat: Workspace & sandbox rework — sandboxed-by-default, scratch dirs, workspace UI, credential injection"
type: feat
date: 2026-02-21
issue: 62
deepened: 2026-02-22
final-review: 2026-02-21
status-updated: 2026-02-22
---

# Workspace & Sandbox Rework

## Enhancement Summary

**Deepened on:** 2026-02-22 (13 agents: python-reviewer, flutter-reviewer, security-sentinel, performance-oracle, architecture-strategist, code-simplicity-reviewer, parachute-conventions-reviewer, agent-native-reviewer, pattern-recognition-specialist, best-practices-researcher, framework-docs-researcher, spec-flow-analyzer, git-history-analyzer)
**First review:** 2026-02-21 (9 agents: python-reviewer, performance-oracle, code-simplicity-reviewer, flutter-reviewer, architecture-strategist, parachute-conventions-reviewer, security-sentinel, pattern-recognition-specialist, docker-best-practices-researcher)

### Key Improvements from Review (Round 1 — 2026-02-21)
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

### Key Improvements from Research & Review (Round 2 — 2026-02-22)
1. **CRITICAL security:** Credentials via stdin JSON, NOT env-file — `docker inspect` exposes all `--env-file` contents
2. **CRITICAL correctness:** `CONTAINER_MEMORY_LIMIT = "512m"` will OOM under normal SDK usage — must be `"1.5g"`; CPU should be `"2.0"`; pids-limit should be `200`
3. **CRITICAL label bug:** Container label is `type=default` but reconcile looks for `type=default-sandbox` — container will be orphaned on every restart
4. **CRITICAL config hash:** `_calculate_config_hash` doesn't include new hardening flags — existing unhardened containers won't be recreated
5. **Bot gating via set:** Use `BOT_SOURCES = {SessionSource.TELEGRAM, SessionSource.DISCORD, SessionSource.MATRIX}` — not string comparison
6. **Chunk 4 may be skippable:** Simplicity reviewer (92%) says existing trust-level filter already passes sandboxed-annotated MCPs through — annotate `parachute` MCP in `.mcp.json` and skip Chunk 4 entirely
7. **Flutter: AsyncNotifier not StateNotifier:** Full codebase already uses `AsyncNotifier` pattern (see `app_state_provider.dart`) — NOT `StateNotifier`
8. **N+1 API call confirmed:** Existing `workspaceSessionsProvider` makes per-chip-tap HTTP calls — must replace with `Provider<AsyncValue<List<ChatSession>>>` doing client-side filtering
9. **Process guard optimization:** `ps aux | wc -l` docker exec adds 80–150ms per message on macOS — use `docker stats --no-stream` with 1-second TTL cache
10. **Flat credentials format:** Nested multi-service YAML adds ~50 LOC translation table with no benefit — flat `GH_TOKEN: value` format is simpler and more flexible
11. **`credentials.py` goes in `lib/`:** It's a pure file-reading utility, not business logic — belongs alongside `lib/auth.py`, not `core/`
12. **Agent-native gap:** No system prompt signal about which tools are authenticated — add credential discoverability to `_build_system_prompt`
13. **Chunk ordering:** Implementation order should be 2 → 6 → 4 → 5 — credentials make tools functional before Chunk 4 exposes them

---

## Implementation Status (as of 2026-02-22)

Verified against codebase by repo-research-analyst.

| Chunk | Status | Remaining Work |
|-------|--------|---------------|
| 1. Trust level rename | ✅ Done | — |
| 2. Default sandbox container | ⚠️ Partial | Missing: `--read-only`, `--memory-reservation`, `--ulimit`, named bridge `parachute-sandbox`, `--add-host`, bot differentiation, `effective_execution_mode` |
| 3. Per-session scratch dirs | ✅ Done | — |
| 4. Server-default MCP config | ❌ Not done | `default_capabilities` in `config.py`; capability filter in orchestrator |
| 5. Workspace chat UI | ⚠️ Partial | `WorkspaceChipRow` not extracted; archived/search views not wired to workspace filter |
| 6. Credential injection | ❌ Not done | `core/credentials.py`; sandbox.py injection; sample `credentials.yaml` |

---

## Overview

Rework how workspaces, chats, and sandboxing relate to each other. The core change: **sandboxed execution becomes the default for all chats**, with workspaces as optional project contexts — not prerequisites for safe code execution. Includes trust level rename, a shared default sandbox container, per-session scratch directories, server-default MCP config, session archiving, and workspace UI improvements.

## Problem Statement

The current system ties sandboxed execution to workspaces. Starting a casual chat either requires a workspace (for sandboxing) or runs on bare metal (unsafe for code execution). The trust level naming (`trusted`/`untrusted`) makes the sandboxed default feel second-class. Workspaces are buried in Settings. Casual chats land in `/workspace` staring at `entrypoint.py`.

## Proposed Solution

Six implementation chunks, ordered by dependency:

1. **Rename trust levels** ✅ — `untrusted` → `sandboxed`, `trusted` → `direct`
2. **Default sandbox container** ⚠️ — always-running shared container for casual chats (hardening flags missing)
3. **Per-session scratch dirs** ✅ — `/scratch/{session_id}/` in every container
4. **Server-default MCP config** ❌ — casual chats get MCPs without a workspace
5. **Workspace-aware chat UI** ⚠️ — workspace switcher in chat tab (chip not extracted, filter not wired to archived/search)
6. **Credential injection** ❌ — `vault/.parachute/credentials.yaml` tokens injected as env vars so `gh`, `aws`, `npm` work in sandboxed sessions

**Separate PR:** Session archiving snackbar-undo (only missing piece — backend + Flutter UI already 90% done).
**Deferred:** Workspace quick-create from New Chat (convenience layer), bot default workspace in `bots.yaml` (YAGNI — no user request).

## Technical Approach

### Phase 1: Foundation (Chunks 1–3)

These are tightly coupled and form the base everything else builds on.

#### Chunk 1: Trust Level Rename ✅ Done

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

#### Chunk 2: Default Sandbox Container ⚠️ Partial

An always-running shared container for casual chats. `run_default()` and `ensure_default_container()` exist. **Still missing:** `--read-only`, `--memory-reservation`, `--ulimit` flags; named bridge network `parachute-sandbox`; `--add-host host.docker.internal:host-gateway`; bot vs. app session differentiation for Docker fallback; `effective_execution_mode` recording. Work needed in `sandbox.py:222-236` and `sandbox.py:553-589`.

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

### Research Insights — Chunk 2

**Concrete bugs to fix before landing (found by 6+ agents):**

1. **Memory/CPU/PIDs constants are wrong** (`sandbox.py:43`):
   ```python
   # Current (wrong)          # Correct
   CONTAINER_MEMORY_LIMIT = "512m"    →  "1.5g"
   CONTAINER_CPU_LIMIT = "1.0"        →  "2.0"
   # --pids-limit 100                 →  200
   # Also add:
   CONTAINER_MEMORY_RESERVATION = "512m"
   ```
   The 512m hard limit will OOM-kill under normal Claude SDK usage (SDK process alone consumes 200–400MB at peak). The 1.5g / 512m soft-reservation split allows ~5 concurrent sessions at 200–300MB each.

2. **Container label mismatch** (`sandbox.py:788`) — current code sets `"type": "default"` but `reconcile()` and the plan both target `"type": "default-sandbox"`. Fix the label; otherwise the default container is orphaned on every server restart.

3. **Config hash must include new flags** (`sandbox.py:132-137`):
   ```python
   def _calculate_config_hash(self) -> str:
       # Include all container-spec values that affect security
       config_str = (
           f"{SANDBOX_IMAGE}:{CONTAINER_MEMORY_LIMIT}:{CONTAINER_CPU_LIMIT}"
           f":read-only:pids200:parachute-sandbox"  # add new flags
       )
       return hashlib.sha256(config_str.encode()).hexdigest()[:12]
   ```
   Without this, `reconcile()` leaves existing unhardened containers running even after the new flags are deployed.

4. **Named bridge network — is it YAGNI?** The simplicity reviewer (88%) argues the named bridge provides no user-visible benefit for a single-user local product — the default Docker bridge with `--add-host host.docker.internal:host-gateway` is sufficient. The architecture reviewer (81%) argues the named bridge is needed for DNS isolation. **Resolution:** Keep the named bridge (security > simplicity here; it's a one-time create at startup). But add `_ensure_network()` to `reconcile()`:
   ```python
   async def _ensure_network(self) -> None:
       proc = await asyncio.create_subprocess_exec(
           "docker", "network", "inspect", "parachute-sandbox",
           stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
       )
       await proc.wait()
       if proc.returncode != 0:
           await asyncio.create_subprocess_exec(
               "docker", "network", "create", "--driver", "bridge",
               "--label", "app=parachute", "parachute-sandbox",
               stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
           )
   ```

5. **Process guard optimization** — `ps aux | wc -l` adds 80–150ms per exec on macOS. Replace with `docker stats --no-stream` plus 1-second TTL cache:
   ```python
   _pid_count_cache: dict[str, tuple[int, float]] = {}

   async def _get_pid_count_cached(self, container_name: str) -> int:
       cached = self._pid_count_cache.get(container_name)
       now = time.time()
       if cached and (now - cached[1]) < 1.0:
           return cached[0]
       proc = await asyncio.create_subprocess_exec(
           "docker", "stats", "--no-stream", "--format", "{{.PIDs}}", container_name,
           stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
       )
       try:
           stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=3.0)
           count = int(stdout.decode().strip())
       except (asyncio.TimeoutError, ValueError):
           count = 0  # fail open — don't block exec on stats timeout
       self._pid_count_cache[container_name] = (count, now)
       return count
   ```
   This reduces per-message overhead from ~100ms to ~1ms (amortized across the 1-second TTL).

6. **Bot source gating — use enum set** (pattern reviewer, 86%):
   ```python
   # models/session.py — alongside SessionSource enum
   BOT_SOURCES = frozenset({SessionSource.TELEGRAM, SessionSource.DISCORD, SessionSource.MATRIX})
   ```
   ```python
   # orchestrator.py — Docker fallback
   if session.source in BOT_SOURCES:
       yield ErrorEvent(error="Docker required for external sessions.").model_dump(by_alias=True)
       return
   else:
       logger.warning(f"Docker unavailable, falling back to direct")
       # fall through to direct execution
   ```
   Do NOT use `session_source == "app"` string compare — misses future external sources.

7. **`effective_execution_mode` — local variable for v1** (simplicity reviewer): Recording this as a DB column requires a migration and adds schema complexity. For v1, use a local variable in the orchestrator to gate capability filtering. Only persist to DB if the audit trail or UI needs it:
   ```python
   # orchestrator.py
   effective_mode: Literal["sandboxed", "direct"] = "sandboxed"
   if docker_unavailable and session.source not in BOT_SOURCES:
       effective_mode = "direct"
   # Use effective_mode (not session.trust_level) when calling filter_by_trust_level()
   ```

8. **`_slug_locks` cleanup** — `stop_container()` removes the workspace lock (`self._slug_locks.pop(workspace_slug, None)`) but there is no equivalent for the default container. Add cleanup in `stop_default_container()` for consistency.

9. **Persistent container memory split** — use separate constants for ephemeral vs. persistent to avoid the same `CONTAINER_MEMORY_LIMIT` applying to both:
   ```python
   CONTAINER_MEMORY_LIMIT_EPHEMERAL = "512m"    # single-session containers
   CONTAINER_MEMORY_LIMIT_PERSISTENT = "1.5g"   # workspace + default containers
   ```

#### Chunk 3: Per-Session Scratch Dirs ✅ Done

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

#### Chunk 4: Server-Default MCP Config ❌ Not Done

Casual chats get default MCPs without needing a workspace. `default_capabilities` field does not yet exist in `config.py`. No server-level capability filter in orchestrator for workspace-less sessions.

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

### Research Insights — Chunk 4

**Consider skipping Chunk 4 entirely (simplicity reviewer, 92% confidence):**

The existing trust-level filter in the orchestrator already passes MCPs annotated `"trust_level": "sandboxed"` through to workspace-less sessions — Stage 2 capability filtering only runs when `workspace_config` is set (orchestrator line 639). If you annotate the `parachute` MCP entry in `.mcp.json` with `"trust_level": "sandboxed"`:

```json
{
  "mcpServers": {
    "parachute": {
      "command": "...",
      "trust_level": "sandboxed"
    }
  }
}
```

...casual sandboxed chats receive it automatically with zero new code. Skip Chunk 4 for the first ship.

**If you do implement Chunk 4, framework docs research confirms:**

1. **Pydantic v2 handles `Optional[WorkspaceCapabilities]` automatically** — no special validators needed. The `_inject_yaml_config` model_validator already passes raw Python dicts; Pydantic coerces `dict → WorkspaceCapabilities` during field validation:
   ```python
   # config.py — add field only
   default_capabilities: Optional[WorkspaceCapabilities] = Field(
       default=None,
       description="Default capabilities for sessions with no workspace. If null, all capabilities pass through.",
   )
   ```
   `WorkspaceCapabilities()` with all defaults (`"all"`) is the correct fallback when the field is absent.

2. **None guard is required in the orchestrator** (architecture reviewer, 83%):
   ```python
   else:
       default_caps = settings.default_capabilities
       if default_caps is not None:
           capabilities = filter_capabilities(
               capabilities=default_caps,
               all_mcps=resolved_mcps,
               all_skills=skill_names,
               all_agents=agent_names,
               plugin_dirs=plugin_dirs,
           )
       # If None: pass through all capabilities unchanged (current behavior)
   ```
   Without this guard, a user without `default_capabilities` in `config.yaml` gets an `AttributeError` on the first casual sandboxed session.

3. **Do NOT add `default_capabilities` to `CONFIG_KEYS`** — it's a nested struct, not a scalar. The `parachute config set` CLI doesn't support nested structures. Users edit `config.yaml` directly.

4. **Optional `env_nested_delimiter`** for env var override:
   ```python
   model_config = {
       # ... existing keys ...
       "env_nested_delimiter": "__",  # enables DEFAULT_CAPABILITIES__MCPS=all
   }
   ```

5. **MCP cache improvement belongs in a separate PR** — adding `stat()` mtime invalidation to the MCP config cache is an independent improvement unrelated to sandbox rework.

#### Chunk 5: Workspace-Aware Chat UI ⚠️ Partial

Move workspace management from Settings into the chat tab. Workspace filtering in `SessionListPanel` and `activeWorkspaceProvider` exist. **Still missing:** `WorkspaceChipRow` widget not extracted (chip is a private `_buildWorkspaceChip()` method on `ChatScreen`); archived sessions and search view not wired to workspace filter. Work needed: create `chat/widgets/workspace_chip_row.dart`; wire filter into `archivedSessionsProvider` and search provider.

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

### Research Insights — Chunk 5

**Use `AsyncNotifier` — not `StateNotifier`** (framework docs research, confirmed across `app_state_provider.dart`):

The entire codebase already uses `AsyncNotifier<T>` + `AsyncNotifierProvider` for persisted state (`ServerUrlNotifier`, `ApiKeyNotifier`, `VaultPathNotifier`, etc.). `StateNotifier` is Riverpod 1.x legacy. Match the existing pattern:

```dart
// chat/providers/workspace_providers.dart
class ActiveWorkspaceNotifier extends AsyncNotifier<String?> {
  static const _key = 'parachute_active_workspace';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);  // null = "All" view
  }

  Future<void> setWorkspace(String? slug) async {
    final prefs = await SharedPreferences.getInstance();
    if (slug != null) {
      await prefs.setString(_key, slug);
    } else {
      await prefs.remove(_key);
    }
    state = AsyncData(slug);
  }
}

final activeWorkspaceProvider = AsyncNotifierProvider<ActiveWorkspaceNotifier, String?>(
  ActiveWorkspaceNotifier.new,
);  // NO autoDispose — app-level persisted state lives for the app lifetime
```

**Consumer-side changes** (every call site of `activeWorkspaceProvider`):
```dart
// Was (StateProvider): ref.watch(activeWorkspaceProvider) → String?
// Now (AsyncNotifier): ref.watch(activeWorkspaceProvider).valueOrNull → String?
// valueOrNull returns null during the ~2ms SharedPreferences load — same as "All" view

// Was: ref.read(activeWorkspaceProvider.notifier).state = slug;
// Now: await ref.read(activeWorkspaceProvider.notifier).setWorkspace(slug);
```

**Fix `workspaceSessionsProvider` N+1 API calls** (performance oracle, 91% confidence; conventions reviewer, 88%):

The existing provider makes a new HTTP call on every chip tap. Replace with synchronous client-side filtering:
```dart
final workspaceSessionsProvider = Provider.autoDispose<AsyncValue<List<ChatSession>>>((ref) {
  final activeSlug = ref.watch(activeWorkspaceProvider).valueOrNull;
  final sessionsAsync = ref.watch(chatSessionsProvider);
  if (activeSlug == null) return sessionsAsync;
  return sessionsAsync.whenData(
    (sessions) => sessions.where((s) => s.workspaceId == activeSlug).toList(),
  );
});
```
Note: return type changes from `FutureProvider<List<ChatSession>>` to `Provider<AsyncValue<List<ChatSession>>>`. Consuming widgets switch from `.future` to `.when()`.

**Simplicity: defer archived/search filter wiring** (simplicity reviewer, 90%):

Active session list filtering is 90% of the user value. Ship `WorkspaceChipRow` with active-list-only filtering. Add `// TODO: wire workspace filter to archived/search views` comment. Deliver archived/search in follow-up PR.

**`WorkspaceChipRow` must use `Wrap` not `Row`** (conventions reviewer, per `app/CLAUDE.md` line 163). Extract as `ConsumerWidget` at `chat/widgets/workspace_chip_row.dart` — do not add as a private `_buildWorkspaceChip()` method on `ChatHubScreen`.

#### Chunk 6: Credential Injection ❌ Not Done

Sandboxed agents cannot use tools like `gh`, `aws`, or `npm publish` because interactive `auth login` flows don't work inside containers. Auth credentials live on the host.

**Solution:** Store tokens in `vault/.parachute/credentials.yaml`. At container launch, inject them as environment variables via the existing env-file mechanism — same path as `CLAUDE_CODE_OAUTH_TOKEN`. Tools pick them up transparently.

```yaml
# vault/.parachute/credentials.yaml
github:
  token: ghp_xxxxx            # → GH_TOKEN
aws:
  access_key: AKIA...         # → AWS_ACCESS_KEY_ID
  secret: ...                 # → AWS_SECRET_ACCESS_KEY
  region: us-east-1           # → AWS_DEFAULT_REGION
npm:
  token: npm_xxx              # → NODE_AUTH_TOKEN
```

**Trust gating:**

| Session type | Credentials |
|---|---|
| `direct` (app/user) | Runs on host natively — already has access |
| `sandboxed` app sessions | Get vault-level credentials from `credentials.yaml` |
| `sandboxed` bot sessions | No credentials by default; must be explicitly opted in |

**Implementation:**

| File | Change |
|------|--------|
| `computer/parachute/core/credentials.py` | **NEW** — load `credentials.yaml`, produce `dict[str, str]` of env var → value |
| `computer/parachute/core/sandbox.py:248-280` | Append credential env vars to ephemeral env-file path |
| `computer/parachute/core/sandbox.py:674-695` | Inject credential env vars into persistent `_run_in_container` stdin payload |
| `computer/sample-vault/.parachute/credentials.yaml` | **NEW** — documented schema with commented-out examples |

**Security:** Credentials are read from vault file at launch time only — never stored in `sessions.db`. Documentation and setup guidance encourage fine-grained scoped tokens (GitHub fine-grained PATs, AWS IAM least-privilege keys) over broad credentials. Bot sessions are excluded by default.

**Dependency:** Requires Chunk 2 container launch infrastructure. Works independently of Chunks 3–5. Declare dependency on issue #69 (rich sandbox image) — `gh` and `aws` binaries must be in `Dockerfile.sandbox` or credential injection is a silent no-op.

### Research Insights — Chunk 6

**1. Use flat credentials format** (simplicity reviewer, 95% confidence — biggest simplification available):

The nested multi-service schema adds ~50 LOC of translation logic with edge cases (what maps `aws.secret` → `AWS_SECRET_ACCESS_KEY`?). The flat format achieves the same result with 7 lines and works for ANY env var the user needs:

```yaml
# vault/.parachute/credentials.yaml — NEW FORMAT (flat)
# Env var name directly as key. Works for any tool.
GH_TOKEN: ghp_xxxxx
# AWS_ACCESS_KEY_ID: AKIA...
# AWS_SECRET_ACCESS_KEY: ...
# AWS_DEFAULT_REGION: us-east-1
# NODE_AUTH_TOKEN: npm_xxx
```

```python
# lib/credentials.py (NOT core/ — it's a pure file utility, same as lib/auth.py)
def load_credentials(vault_path: Path) -> dict[str, str]:
    """Load vault credentials.yaml → flat env var dict. Returns {} if absent."""
    path = vault_path / ".parachute" / "credentials.yaml"
    if not path.exists():
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except Exception:
        return {}
    return {k: str(v) for k, v in data.items() if isinstance(v, str)}
```

**2. CRITICAL: credentials via stdin JSON, NOT env-file** (security sentinel, F1):

`docker inspect <container>` shows ALL environment variables passed via `--env-file`. This means credentials in the env-file are visible to any host process that can run `docker inspect`. Use the stdin JSON path (same as `claude_token`):

```python
# sandbox.py — _run_in_container (persistent containers)
stdin_payload["credentials"] = load_credentials(self.vault_path)  # dedicated key
# NOT: append to env_lines in _build_run_args

# entrypoint.py — before constructing ClaudeAgentOptions
creds = data.get("credentials", {})
os.environ.update(creds)  # apply to process env before SDK starts
```

For ephemeral containers: pass credentials in the stdin payload via the `--env-file` mechanism ONLY if the entrypoint reads them from stdin. If using `--env-file`, filter through process args which are also visible in `ps aux` — use stdin payload instead for ephemeral too.

**3. Bot session gating** (security sentinel F3, pattern reviewer 86%):

```python
# Call load_credentials only for app sessions
from parachute.models.session import BOT_SOURCES

credential_env = {}
if effective_trust == "sandboxed" and session.source not in BOT_SOURCES:
    credential_env = load_credentials(self.vault_path)
```

Define `BOT_SOURCES` in `models/session.py` alongside `SessionSource` enum — not inline at the call site.

**4. Env var name validation** — blocklist dangerous override names:

```python
_BLOCKED_ENV_VARS = frozenset({
    "CLAUDE_CODE_OAUTH_TOKEN", "PATH", "LD_PRELOAD", "LD_LIBRARY_PATH",
    "HOME", "USER", "SHELL", "PYTHONPATH",
})

def load_credentials(vault_path: Path) -> dict[str, str]:
    # ... load yaml ...
    return {
        k: str(v)
        for k, v in data.items()
        if isinstance(v, str) and k not in _BLOCKED_ENV_VARS
    }
```

**5. Reserve `workspaces:` namespace in schema** (architecture reviewer, 84%):

Even though the loader ignores it in v1, include `workspaces:` as a documented YAML key so the schema is migration-safe:

```yaml
# vault/.parachute/credentials.yaml
GH_TOKEN: ghp_xxxxx

# workspace-scoped overrides (v2 — ignored by v1 loader)
# workspaces:
#   client-project:
#     GH_TOKEN: ghp_different_token
```

**6. Agent-native gap: system prompt credential discoverability** (agent-native reviewer, 91%):

Without a prompt signal, the agent only uses `gh` if the user explicitly asks. Add to `_build_system_prompt` in `orchestrator.py`:

```python
# Load credentials ONCE on host before launching sandbox (no values in prompt)
cred_keys = set(load_credentials(vault_path).keys())
if cred_keys:
    authenticated_tools = []
    if "GH_TOKEN" in cred_keys:
        authenticated_tools.append("`gh` (GitHub CLI — pre-authenticated)")
    if "AWS_ACCESS_KEY_ID" in cred_keys:
        authenticated_tools.append("`aws` (AWS CLI — pre-authenticated)")
    if "NODE_AUTH_TOKEN" in cred_keys or "NPM_TOKEN" in cred_keys:
        authenticated_tools.append("`npm` (authenticated for publish)")
    if authenticated_tools:
        append_parts.append(
            "## Authenticated CLI Tools\n\n"
            + "\n".join(f"- {t}" for t in authenticated_tools)
        )
```

**7. Log discipline** — log key names only, never values:
```python
logger.debug(f"Injecting credentials: {list(credential_env.keys())}")  # OK
logger.debug(f"Injecting credentials: {credential_env}")               # NEVER
```

**8. Mtime cache** — consistent with the planned `.mcp.json` cache improvement:
```python
_credentials_cache: Optional[dict[str, str]] = None
_credentials_mtime: float = 0.0

def load_credentials(vault_path: Path) -> dict[str, str]:
    global _credentials_cache, _credentials_mtime
    path = vault_path / ".parachute" / "credentials.yaml"
    if not path.exists():
        return {}
    mtime = path.stat().st_mtime
    if _credentials_cache is not None and mtime == _credentials_mtime:
        return _credentials_cache
    # ... load and parse ...
    _credentials_cache = result
    _credentials_mtime = mtime
    return result
```

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
- [ ] `gh` commands work inside sandboxed sessions when `GH_TOKEN` set in `credentials.yaml`
- [ ] `credentials.yaml` tokens injected via existing env-file path at container launch
- [ ] Bot sessions receive no credentials unless explicitly configured
- [ ] Credentials never written to `sessions.db`

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
| Credential exposure in container | Medium — token in container env if container compromised | Fine-grained scoped tokens; bot sessions excluded by default; credentials never in `sessions.db` |

## References

### Internal
- Issue #62 brainstorm: workspace & chat organization rethink
- `docs/brainstorms/2026-02-22-sandbox-host-tool-proxy-brainstorm.md` — Chunk 6 credential injection design
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
