---
title: "feat: Sandbox Session Persistence"
type: feat
date: 2026-02-16
issue: 26
depends_on: [33]
---

# Sandbox Session Persistence

## Enhancement Summary

**Deepened on:** 2026-02-16
**Research agents used:** agent-native-architecture, python-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist, spec-flow-analyzer, best-practices-researcher, framework-docs-researcher

### Key Improvements from Research
1. **`--session-id` CLI flag discovered** — SDK supports caller-specified session IDs via `extra_args`, eliminating the session ID mismatch problem entirely
2. **Three-tier fallback design** — resume → history injection → fresh query (no cliff-edge context loss)
3. **Deterministic transcript path** — compute exact path from container CWD instead of glob (eliminates symlink traversal risk)
4. **Shared validation module** — extract slug validator to `core/validation.py` to prevent circular imports

### Key Risks Identified
1. `Path.glob()` follows symlinks — replaced with deterministic path computation
2. `set_session_metadata()` doesn't exist — no longer needed thanks to `--session-id`
3. Container must be stopped before workspace deletion cleanup
4. Docker bind mounts do NOT support `nosuid,nodev,noexec,nosymfollow` — symlink defense must be at application layer

---

## Overview

Enable SDK session data to persist across container restarts in persistent workspace containers. Currently, each `docker exec` invocation is a fresh SDK query — the agent has no memory of prior turns beyond synthetic history injection. By mounting a host directory as the SDK's `.claude/` storage, we get native SDK resume support, real transcripts, and consistent behavior with trusted sessions.

## Problem Statement

With persistent containers (PR #38), the Docker container itself survives across sessions. But the SDK's internal state — transcripts, session metadata — lives inside the container's writable layer at `/home/sandbox/.claude/`. When a container is OOM-killed, force-recreated, or the Docker daemon restarts, all SDK data is lost.

**Current workaround** (`orchestrator.py:835-841`):
```python
if had_text:
    self.session_manager.write_sandbox_transcript(
        sandbox_sid, actual_message, sandbox_response_text,
        working_directory=effective_working_dir,
    )
```

This synthetic transcript captures text but loses tool calls, thinking blocks, and SDK metadata. It also doesn't support the SDK's `resume` feature — each container invocation starts fresh with history injected as a text blob (`orchestrator.py:753-771`).

**Impact**: Sandbox sessions feel stateless. Multi-turn conversations require re-injecting full history as text, which grows as O(n^2) in tokens over the session lifetime. Trusted sessions get native resume with full fidelity; sandbox sessions don't. SDK resume would give **5-10x input token reduction** and **1-2s latency improvement** per turn for multi-turn sessions.

## Proposed Solution

Mount a per-workspace host directory into persistent containers so the SDK writes its `.claude/` data to the host filesystem. This gives sandbox sessions the same persistence model as trusted sessions.

### Architecture

```
Host filesystem:
  vault/.parachute/sandbox/{workspace_slug}/.claude/
    └── projects/
        └── {encoded_container_cwd}/
            └── {sandbox_sid}.jsonl    # SDK transcript (using OUR session ID)

Container mount:
  -v vault/.parachute/sandbox/{slug}/.claude:/home/sandbox/.claude:rw

SDK inside container:
  --session-id {sandbox_sid}           # Tell SDK to use our ID
  Writes to /home/sandbox/.claude/projects/{encoded_cwd}/{sandbox_sid}.jsonl
  Resume uses same sandbox_sid — IDs match by construction
```

### Key Design Decisions

#### 1. Per-workspace, not per-session

One `.claude/` directory per workspace slug, shared by all sessions in that workspace. This matches the 1:1 container-per-workspace model from PR #38.

```
vault/.parachute/sandbox/
├── my-project/.claude/        # All sessions in "my-project" workspace
├── research-tools/.claude/    # All sessions in "research-tools" workspace
```

#### 2. Use `--session-id` to align SDK and DB IDs

**Key discovery from SDK research**: The Claude CLI (v2.1.42) supports `--session-id <uuid>` via `ClaudeAgentOptions.extra_args`. This tells the SDK to use a caller-specified UUID for the session, rather than generating its own.

```python
options_kwargs["extra_args"] = {"session-id": sandbox_sid}
```

This eliminates the entire "session ID mismatch" problem. The SDK writes transcripts as `{sandbox_sid}.jsonl` — the same ID stored in our database. No need to capture the SDK's internal ID, no metadata storage needed, no dual-ID bookkeeping.

**Why this is better than the capture-and-store approach:**
- No phantom `set_session_metadata()` API needed
- No timing issue (DB row doesn't need to exist when `session` event fires)
- No metadata overwrite risk
- Transcript path is deterministic (no glob needed)
- Resume uses `sandbox_sid` directly

#### 3. Three-tier resume fallback

**Insight from agent-native architecture review**: The original plan had a cliff-edge failure mode — resume fails and the agent gets zero context. The improved design has three tiers:

1. **SDK resume** (best): transcript exists, SDK loads full-fidelity context
2. **History injection** (good): no transcript or resume fails, orchestrator injects prior messages as text
3. **Fresh query** (worst): no history available at all (first message, or all fallbacks exhausted)

When resume fails, the entrypoint emits a structured `resume_failed` event. The orchestrator catches it and retries with history injection — never drops directly to zero context.

#### 4. Keep `write_sandbox_transcript()` as fallback

Don't remove the synthetic transcript writer. It continues to serve:
- Fallback for ephemeral (non-workspace) sessions with no persistent storage
- Source of host-accessible transcripts for session list/search
- History injection source when resume is not available

#### 5. No host-side transcript discovery (yet)

As long as `write_sandbox_transcript()` runs, the existing session manager can find transcripts via its current search paths. Adding a third search location (sandbox `.claude/` dirs) is redundant and introduces O(W×P) filesystem scans with symlink traversal risks. Defer until the synthetic writer is removed.

## Technical Approach

### Pre-work: Unify slug validation

**Files**: new `core/validation.py`, `sandbox.py`, `workspaces.py`, `requests.py`

The two `_validate_slug` functions have different regex patterns:
- `workspaces.py:30`: `^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$` (strict lowercase)
- `sandbox.py:408`: `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` (allows uppercase + underscores)

**Fix**: Extract to a shared validation module to avoid circular imports between peer components.

```python
# core/validation.py — new file, shared validators
import re

_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$")
SANDBOX_DATA_DIR = ".parachute/sandbox"

def validate_workspace_slug(slug: str) -> None:
    """Validate a workspace slug. Raises ValueError on invalid input."""
    if not slug or "/" in slug or "\\" in slug or ".." in slug:
        raise ValueError(f"Invalid workspace slug: {slug!r}")
    if not _SLUG_PATTERN.match(slug):
        raise ValueError(f"Invalid workspace slug: {slug!r}")
```

```python
# requests.py — ChatRequest
workspace_id: str | None = Field(
    alias="workspaceId",
    default=None,
    pattern=r"^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$",
    description="Workspace slug",
)
```

```python
# sandbox.py and workspaces.py — both import from validation.py
from parachute.core.validation import validate_workspace_slug, SANDBOX_DATA_DIR
```

### Main implementation

**Files**: `sandbox.py`, `orchestrator.py`, `entrypoint.py`, `workspaces.py`, `api/workspaces.py`

#### 1. Mount `.claude/` into persistent containers

Add a public method to `DockerSandbox` and use it in `_create_persistent_container()`:

```python
# sandbox.py — public method on DockerSandbox
def get_sandbox_claude_dir(self, workspace_slug: str) -> Path:
    """Host-side .claude/ directory for a workspace's sandbox."""
    validate_workspace_slug(workspace_slug)
    return self.vault_path / SANDBOX_DATA_DIR / workspace_slug / ".claude"

def has_sdk_transcript(self, workspace_slug: str, session_id: str) -> bool:
    """Check if an SDK transcript exists on the host mount for a workspace session."""
    claude_dir = self.get_sandbox_claude_dir(workspace_slug)
    # Compute deterministic path using container CWD encoding
    # The SDK encodes CWD as dash-separated path components
    projects_dir = claude_dir / "projects"
    if not projects_dir.exists():
        return False
    # Session ID is a UUID — safe for path construction
    filename = f"{session_id}.jsonl"
    for project_dir in projects_dir.iterdir():
        if project_dir.is_symlink():
            continue  # Skip symlinks — defense against container-created links
        candidate = project_dir / filename
        if candidate.exists() and not candidate.is_symlink():
            return True
    return False
```

In `_create_persistent_container()` (`sandbox.py:454`):

```python
# sandbox.py — _create_persistent_container()
sandbox_claude_dir = self.get_sandbox_claude_dir(workspace_slug)
sandbox_claude_dir.mkdir(parents=True, exist_ok=True)
# Sync I/O acceptable: single mkdir + chmod, serialized behind _slug_locks
sandbox_claude_dir.chmod(0o700)

args.extend(["-v", f"{sandbox_claude_dir}:/home/sandbox/.claude:rw"])
```

#### 2. Pass `--session-id` to SDK via entrypoint

In `entrypoint.py`, tell the SDK to use our session ID:

```python
# entrypoint.py — after building options_kwargs (replace lines 126-129)
session_id = os.environ.get("PARACHUTE_SESSION_ID", "")

# Tell SDK to use our session ID so transcript filenames match our DB
if session_id:
    options_kwargs.setdefault("extra_args", {})["session-id"] = session_id

# Resume from prior transcript if available
resume_id = request.get("resume_session_id")
if resume_id:
    options_kwargs["resume"] = resume_id
```

Extract the event processing loop to avoid duplication in the retry path:

```python
# entrypoint.py — extracted helper
async def run_query_and_emit(message: str, options: ClaudeAgentOptions) -> str | None:
    """Run SDK query, emit events to stdout. Returns captured session ID."""
    current_text = ""
    captured_session_id = None
    captured_model = None

    async for event in query(prompt=message, options=options):
        event_type = type(event).__name__
        # ... existing event processing (lines 140-182) ...

    emit({"type": "done", "sessionId": captured_session_id or ""})
    return captured_session_id
```

Resume with three-tier fallback:

```python
# entrypoint.py — in run(), after building options
options = ClaudeAgentOptions(**options_kwargs)

try:
    await run_query_and_emit(message, options)
except Exception as e:
    if resume_id:
        # Resume failed — emit structured event so orchestrator can retry with history
        emit({"type": "resume_failed", "error": str(e), "session_id": resume_id})
        emit({"type": "done", "sessionId": session_id or ""})
        sys.exit(0)  # Clean exit — orchestrator handles retry
    else:
        raise
```

#### 3. Enable resume in orchestrator

In the sandbox code path (`orchestrator.py`, around line 753):

```python
# orchestrator.py — sandbox code path, before building sandbox_message
resume_session_id = None
if not is_new and workspace_id:
    has_transcript = await asyncio.to_thread(
        self._sandbox.has_sdk_transcript, workspace_id, sandbox_sid
    )
    if has_transcript:
        resume_session_id = sandbox_sid

if resume_session_id:
    # SDK will resume from transcript — no history injection needed
    sandbox_message = actual_message
else:
    # Fallback: inject history as text (no transcript available)
    # ... existing history injection logic (lines 753-771) ...
```

Pass `resume_session_id` through to `run_persistent()`:

```python
# orchestrator.py — calling run_persistent
sandbox_stream = self._sandbox.run_persistent(
    workspace_slug=workspace_id,
    config=sandbox_config,
    message=sandbox_message,
    resume_session_id=resume_session_id,
)
```

Handle `resume_failed` event in the sandbox event loop:

```python
# orchestrator.py — in sandbox event loop
if event_type == "resume_failed":
    logger.warning(f"SDK resume failed for {sandbox_sid[:8]}, retrying with history injection")
    # Rebuild message with history injection
    prior_messages = await self.session_manager._load_sdk_messages(session)
    if prior_messages:
        history_lines = []
        for msg in prior_messages:
            role = msg["role"].upper()
            history_lines.append(f"[{role}]: {msg['content']}")
        history_block = "\n".join(history_lines)
        sandbox_message = (
            f"<conversation_history>\n{history_block}\n"
            f"</conversation_history>\n\n{actual_message}"
        )
    else:
        sandbox_message = actual_message

    # Retry without resume
    sandbox_stream = self._sandbox.run_persistent(
        workspace_slug=workspace_id,
        config=sandbox_config,
        message=sandbox_message,
        # No resume_session_id — fresh query with history
    )
    # Continue processing from new stream...
    continue
```

#### 4. Pass resume ID via stdin payload

Add `resume_session_id` parameter to `run_persistent()`:

```python
# sandbox.py — run_persistent() signature
async def run_persistent(
    self,
    workspace_slug: str,
    config: AgentSandboxConfig,
    message: str,
    resume_session_id: str | None = None,
) -> AsyncGenerator[dict, None]:
```

In the stdin payload construction:

```python
# sandbox.py — run_persistent(), building stdin_payload
stdin_payload: dict = {"message": message}
if resume_session_id:
    stdin_payload["resume_session_id"] = resume_session_id
```

#### 5. Workspace deletion cleanup

The workspace deletion flow must stop the container before cleaning up sandbox data. The cleanup logic belongs in `DockerSandbox`, not `workspaces.py`:

```python
# sandbox.py — new method on DockerSandbox
def cleanup_workspace_data(self, workspace_slug: str) -> None:
    """Remove persistent sandbox data for a workspace."""
    validate_workspace_slug(workspace_slug)
    sandbox_dir = self.vault_path / SANDBOX_DATA_DIR / workspace_slug
    if sandbox_dir.exists() and not sandbox_dir.is_symlink():
        shutil.rmtree(sandbox_dir)
    elif sandbox_dir.is_symlink():
        logger.warning(f"Sandbox dir is a symlink, removing link only: {sandbox_dir}")
        sandbox_dir.unlink()
```

The API endpoint (`api/workspaces.py`) calls both:

```python
# api/workspaces.py — delete_workspace endpoint
# 1. Stop the container first (existing call)
await orchestrator.stop_workspace_container(slug)
# 2. Clean up sandbox persistent data
orchestrator._sandbox.cleanup_workspace_data(slug)
# 3. Delete workspace config
delete_workspace(vault_path, slug)
```

## Security Considerations

### Symlink escape via container writes

The container gets RW access to the mounted `.claude/` directory. Creating symlinks requires no Linux capabilities — the sandbox user can do it despite `--cap-drop ALL` (confirmed: `symlink()` syscall requires only write permission to the directory, no capabilities).

**Mitigations:**
- **Symlink-aware transcript check**: `has_sdk_transcript()` skips symlinked directories and files with explicit `is_symlink()` checks
- **No host-side directory traversal**: By deferring host-side transcript discovery, we avoid the riskiest code path
- **Symlink guard on cleanup**: `cleanup_workspace_data()` checks `not is_symlink()` before `shutil.rmtree()`
- **Docker mount options**: Docker bind mounts do NOT support `nosuid,nodev,noexec,nosymfollow` flags ([moby/moby#12143](https://github.com/moby/moby/issues/12143)). The `nosymfollow` kernel flag (Linux 5.10+) exists but cannot be applied via Docker `-v` syntax. Defense must be at the application layer.

### UID/GID permissions

On macOS Docker Desktop with VirtioFS, UID translation is handled transparently — container UID 1000 writes appear as the host user on the macOS side. On Linux, UID 1000 maps directly and may mismatch the host user.

**Mitigation**: Create the host directory with `0o700` permissions. macOS works out of the box. Document Linux UID mapping for future (`--user $(id -u):$(id -g)` or `--userns-remap`).

### Trust boundary expansion

This plan gives sandboxed containers persistent RW access to a host directory. This is a deliberate, controlled expansion of the sandbox trust boundary — the mount scope is narrow (`vault/.parachute/sandbox/{slug}/.claude`), the container cannot access the vault broadly, and the host-side code that reads from this directory is explicitly symlink-aware.

### Slug validation at all boundaries

Unified slug validation (pre-work step) ensures the slug used in path construction has been validated by the same strict pattern at: API boundary (Pydantic), workspace layer, and sandbox layer.

## Edge Cases

### Container OOM kill + recreation
- SDK data is on host, not in container writable layer
- When `ensure_container()` recreates after OOM, it re-mounts the same host directory
- All prior transcripts are preserved and resume works

### Ephemeral (non-workspace) sessions
- No persistent storage — existing behavior unchanged
- `write_sandbox_transcript()` continues to handle these
- No resume support for ephemeral sessions

### First message in a session
- `is_new=True`, resume not attempted
- SDK uses `--session-id {sandbox_sid}` so transcript is written as `{sandbox_sid}.jsonl`
- After response, `write_sandbox_transcript()` also writes synthetic copy

### Resume fails (corrupted transcript)
- Entrypoint emits `resume_failed` event with error details
- Orchestrator catches it, retries with history injection (not fresh query)
- Three-tier fallback: resume → history injection → fresh (only if no history)

### Legacy session (pre-feature)
- Session has synthetic transcript but no SDK transcript on mount
- `has_sdk_transcript()` returns false, falls through to history injection
- First invocation with `--session-id` creates the SDK transcript
- Subsequent invocations use resume — session is "upgraded" to native persistence

### Workspace deletion and recreation
- API endpoint stops container, cleans up sandbox data, then deletes workspace config
- Old SDK transcripts are removed; new workspace starts fresh
- Old sessions in DB still exist but `has_sdk_transcript()` returns false → history injection fallback

### Concurrent messages to same new session
- Pre-existing issue: two `docker exec` invocations can run simultaneously
- Both use `--session-id {sandbox_sid}` so both write to the same transcript file
- SDK handles concurrent appends to different messages within the same JSONL
- Document as known limitation — not worsened by this plan

## Acceptance Criteria

- [x] Persistent containers mount `vault/.parachute/sandbox/{slug}/.claude` to `/home/sandbox/.claude`
- [x] Host directory created with `0o700` permissions before container creation
- [x] Slug validation unified in `core/validation.py`, imported by sandbox and workspaces
- [x] `ChatRequest.workspace_id` has Pydantic pattern validation
- [x] Entrypoint passes `--session-id {sandbox_sid}` via `extra_args` so transcript filenames match DB
- [x] Continuing sessions use SDK resume when transcript exists on host mount
- [x] First message works normally (no resume, creates transcript with our session ID)
- [x] Resume failure triggers `resume_failed` event → orchestrator retries with history injection
- [x] Entrypoint event processing extracted to helper function (no duplication in retry path)
- [x] Workspace deletion stops container, cleans sandbox data (with symlink guard), then deletes config
- [x] `has_sdk_transcript()` method on DockerSandbox skips symlinks during directory iteration
- [x] Ephemeral containers are unaffected (no mount)
- [x] Container OOM + recreation preserves SDK data on host
- [x] `write_sandbox_transcript()` continues running as fallback
- [x] Uses `str | None` (not `Optional[str]`) in new code
- [x] Uses `Path.chmod()` (not `os.chmod()`) for consistency

## Dependencies

- **PR #38** (merged): Persistent Docker containers per workspace
- **Claude Agent SDK >= 0.1.29**: `extra_args` support for `--session-id` flag
- **No other external dependencies**: Uses existing Docker bind mount mechanics

## Risks

| Risk | Mitigation |
|------|-----------|
| `--session-id` flag behavior changes in future SDK | Pin SDK version; flag is part of CLI interface, unlikely to break |
| Symlink escape from container writes | `has_sdk_transcript()` skips symlinks; no host-side traversal of sandbox mounts |
| UID mismatch on Linux | Create dir with 0o700; document Linux requirement; macOS virtiofs handles it |
| Disk growth from accumulated transcripts | Workspace deletion cleans up; extend `cleanup_old_sessions()` (future) |
| Resume breaks on corrupted transcript | Three-tier fallback: resume → history injection → fresh query |
| Slug validation bypass | Unified validator at API, workspace, and sandbox layers |
| Blocking I/O in async context | `has_sdk_transcript()` wrapped in `asyncio.to_thread()` |
| Container still running when sandbox data deleted | API endpoint stops container before cleanup |

## Files Changed

| File | Change |
|------|--------|
| `core/validation.py` | **New** — shared `validate_workspace_slug()` and `SANDBOX_DATA_DIR` constant |
| `core/sandbox.py` | Add mount in `_create_persistent_container()`, `get_sandbox_claude_dir()`, `has_sdk_transcript()`, `cleanup_workspace_data()`, `resume_session_id` param on `run_persistent()`, import from `validation.py` |
| `core/orchestrator.py` | Resume decision before history injection, pass `resume_session_id` to `run_persistent()`, handle `resume_failed` event |
| `docker/entrypoint.py` | Add `--session-id` via `extra_args`, add `resume` from stdin, extract `run_query_and_emit()` helper, emit `resume_failed` on failure |
| `core/workspaces.py` | Import from `validation.py` (replace local `_validate_slug`) |
| `api/workspaces.py` | Call `cleanup_workspace_data()` and stop container on workspace deletion |
| `models/requests.py` | Add `pattern` validation to `ChatRequest.workspace_id` |

## References

- Issue #26: https://github.com/OpenParachutePBC/parachute-computer/issues/26
- PR #38: Persistent Docker containers per workspace (dependency)
- Claude Agent SDK `--session-id`: CLI flag via `ClaudeAgentOptions.extra_args` (SDK v0.1.36, CLI v2.1.42)
- Claude Agent SDK resume: `ClaudeAgentOptions.resume` → CLI `--resume <session_id>`
- Docker bind mount limitations: [moby/moby#12143](https://github.com/moby/moby/issues/12143) — `nosuid/nodev/noexec` not supported
- `nosymfollow` kernel flag: Linux 5.10+ but not exposed by Docker CLI
- VirtioFS UID mapping: Docker Desktop for Mac handles transparently; Linux needs explicit UID alignment
- `computer/parachute/core/sandbox.py:454-496` — `_create_persistent_container()`
- `computer/parachute/core/sandbox.py:498-605` — `run_persistent()`
- `computer/parachute/core/sandbox.py:408-411` — `_validate_slug()` (to be replaced)
- `computer/parachute/core/orchestrator.py:753-771` — History injection
- `computer/parachute/core/orchestrator.py:807-812` — Session ID rewriting
- `computer/parachute/core/orchestrator.py:835-841` — Synthetic transcript write
- `computer/parachute/core/session_manager.py:424-460` — `_find_sdk_session_location()`
- `computer/parachute/core/session_manager.py:646-681` — `write_sandbox_transcript()`
- `computer/parachute/docker/entrypoint.py:126-129` — Resume disabled (to be enabled)
- `computer/parachute/core/workspaces.py:30-38` — Slug validation (to be extracted)
- `computer/parachute/core/workspaces.py:158-167` — `delete_workspace()`
- `computer/parachute/models/requests.py:139-143` — `ChatRequest.workspace_id`
- SDK source: `computer/.venv/lib/python3.14/site-packages/claude_agent_sdk/_internal/transport/subprocess_cli.py:291-298` — `extra_args` handling
