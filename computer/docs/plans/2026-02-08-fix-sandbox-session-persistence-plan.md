---
title: "Fix Sandbox Session Persistence"
type: fix
date: 2026-02-08
---

# Fix Sandbox Session Persistence

## Overview

Sandboxed chat sessions lose their trust level after the first message. The second message can't find the session in the DB, creates a new one defaulting to `full` trust, and the sandbox is silently dropped. Additionally, each sandboxed message is a fresh conversation with no memory because Docker containers are ephemeral and transcripts are lost on `--rm`.

This plan fixes both problems: session persistence and conversation continuity.

## Problem Statement

**Observed behavior** (from server logs):

```
Message 1: sandbox session created → sandbox_sid=0bb62b20, trust=sandboxed ✓
Message 2: session lookup fails → "Unknown session ID: 0bb62b20-..., treating as new session"
         → new session created with trust_level=NULL → defaults to full ✗
```

**Root causes:**

1. **Session lookup succeeds in DB but fails transcript check** — `get_or_create_session()` finds the session in SQLite, but `_check_sdk_session_exists()` returns False (transcript was inside the destroyed container). The orchestrator then forces `is_new = True`, creating a fresh session that loses the trust level.
   - `orchestrator.py:523-535` — forces `is_new = True` when no SDK transcript exists
   - But wait — the logs show `"Unknown session ID requested"` which means `db.get_session()` returned None. This suggests `finalize_session()` may not have completed before the second message arrived, OR the session was finalized with a different ID.

2. **Container transcripts are lost** — The `--rm` flag destroys the container after each message. Transcripts written to `/home/sandbox/.claude/projects/` inside the container vanish. No `--resume` is possible.

3. **No SDK session ID mapping** — The container's internal SDK session ID differs from the `sandbox_sid` stored in the DB. Even with mounted transcripts, there's no way to know which JSONL file to resume.

## Proposed Solution

### Architecture

```
vault/
└── .workspaces/
    └── {sandbox_sid}/           ← auto-created per sandboxed session
        ├── .claude/
        │   └── projects/
        │       └── -workspace/
        │           └── {sdk_session_id}.jsonl   ← persists across container runs
        └── (user files created by the sandbox)

Docker container:
  -v vault/.workspaces/{sid}:/home/sandbox:rw    ← HOME mount
  -e HOME=/home/sandbox                          ← CLI writes .claude/ here
  WORKDIR /workspace                             ← consistent CWD for path encoding
  stdin: {"message": "...", "resume": "sdk-session-id"}  ← resume protocol
```

**Flow: First message (new sandboxed session)**
1. Orchestrator generates `sandbox_sid` (UUID)
2. Creates workspace dir: `vault/.workspaces/{sandbox_sid}/`
3. Mounts workspace at `/home/sandbox` in the container
4. Container runs, SDK creates transcript at `/home/sandbox/.claude/projects/-workspace/{sdk_session_id}.jsonl`
5. Orchestrator captures the container's SDK session ID from the `session` event
6. Finalizes session in DB: `id=sandbox_sid`, `trust_level=sandboxed`, `metadata.sandbox_sdk_session_id={sdk_id}`
7. Rewrites session event to client with `sandbox_sid`

**Flow: Follow-up message (existing sandboxed session)**
1. Client sends `sessionId=sandbox_sid`
2. `get_or_create_session()` finds it in DB with `trust_level=sandboxed`
3. Orchestrator reads `metadata.sandbox_sdk_session_id` for resume
4. Mounts same workspace at `/home/sandbox`
5. Passes `{"message": "...", "resume": "{sdk_session_id}"}` to container
6. Container SDK finds transcript, resumes conversation
7. Full continuity achieved

## Technical Approach

### Change 1: Fix session finalization and lookup for sandbox sessions

**Files:** `computer/parachute/core/orchestrator.py`, `computer/parachute/core/session_manager.py`

**Problem:** The sandbox path at `orchestrator.py:575-619` finalizes the session, but the transcript check at `orchestrator.py:523-535` forces `is_new = True` for sandbox sessions because no host-side transcript exists. For sandbox sessions, we should skip the host-side transcript check entirely — the transcript lives in the workspace, not in `~/.claude/projects/`.

**Changes:**
- In the transcript existence check (`orchestrator.py:523-535`), skip for sessions with `trust_level=sandboxed`. The workspace has the transcript; the host doesn't need one.
- Ensure `sandbox_sid` is passed correctly to `finalize_session()` and that `trust_level` propagates from the placeholder to the DB row (verify this works — add logging if needed).
- Store the container's SDK session ID in session metadata after the first run: `session.metadata["sandbox_sdk_session_id"] = captured_sdk_id`.

```python
# orchestrator.py — skip transcript check for sandboxed sessions
if session.id != "pending" and not is_new and not force_new:
    session_trust = session.get_trust_level()
    if session_trust == TrustLevel.SANDBOXED:
        # Sandbox transcripts live in workspace, not host ~/.claude/
        resume_id = None  # Will be handled by sandbox path using metadata
    elif self.session_manager._check_sdk_session_exists(
        session.id, session.working_directory
    ):
        resume_id = session.id
    else:
        logger.info(f"Session {session.id[:8]} exists in DB but has no SDK transcript, treating as new")
        is_new = True
```

### Change 2: Create workspace directories for sandboxed sessions

**Files:** `computer/parachute/core/orchestrator.py`, `computer/parachute/core/sandbox.py`

**Changes:**
- Before running the sandbox container, create `vault/.workspaces/{sandbox_sid}/` if it doesn't exist
- Pass the workspace path to `DockerSandbox.run_agent()` as a new parameter
- The workspace directory is the container's writable home; the `.claude/` subdirectory is created automatically by the SDK inside the container

```python
# orchestrator.py — before sandbox execution
workspace_path = self.vault_path / ".workspaces" / sandbox_sid
workspace_path.mkdir(parents=True, exist_ok=True)
```

### Change 3: Mount workspace as container HOME

**Files:** `computer/parachute/core/sandbox.py`

**Changes to `_build_mounts()`:**
- Add the workspace mount: `-v {workspace_path}:/home/sandbox:rw`
- This replaces the sandbox user's home directory with the workspace
- The SDK writes to `$HOME/.claude/projects/-workspace/{session_id}.jsonl` which lands in the mounted workspace

**Changes to `_build_run_args()`:**
- Add `-e HOME=/home/sandbox` explicitly (defensive — should already be the default but making it explicit ensures correctness)
- Accept `workspace_path` as a parameter and incorporate into mount list

```python
# sandbox.py — _build_mounts() addition
def _build_mounts(self, config: AgentSandboxConfig, workspace_path: Optional[Path] = None) -> list[str]:
    mounts = []
    # Mount workspace as sandbox user's home (for transcript persistence)
    if workspace_path and workspace_path.exists():
        mounts.extend(["-v", f"{workspace_path}:/home/sandbox:rw"])
    # ... existing vault mount logic ...
```

### Change 4: Extend entrypoint to support `--resume`

**Files:** `computer/parachute/docker/entrypoint.py`

**Changes:**
- Accept `resume` field in the stdin JSON: `{"message": "...", "resume": "sdk-session-id"}`
- When `resume` is present, pass it to `ClaudeAgentOptions(resume=resume_id)`
- Remove the comment about intentionally not using resume (it's now supported)

```python
# entrypoint.py
data = json.loads(sys.stdin.read())
message = data["message"]
resume_id = data.get("resume")  # None on first message, SDK session ID on follow-up

options_kwargs = {
    "permission_mode": "bypassPermissions",
    "env": {"CLAUDE_CODE_OAUTH_TOKEN": oauth_token},
}
if resume_id:
    options_kwargs["resume"] = resume_id
```

### Change 5: Capture and store container SDK session ID

**Files:** `computer/parachute/core/orchestrator.py`

**Changes:**
- In the sandbox event loop (`orchestrator.py:595-602`), capture the SDK session ID from `session` events BEFORE rewriting
- After the sandbox run completes and the session is finalized, store the captured SDK session ID in session metadata

```python
# orchestrator.py — in sandbox event loop
container_sdk_session_id = None
async for event in self._sandbox.run_agent(sandbox_config, message, ...):
    event_type = event.get("type", "")
    # Capture container's SDK session ID before rewriting
    if event_type == "session" and "sessionId" in event:
        container_sdk_session_id = event["sessionId"]
    # Rewrite to sandbox_sid for client
    if event_type in ("session", "done") and "sessionId" in event:
        event = {**event, "sessionId": sandbox_sid, "trustLevel": effective_trust}
    yield event

# After sandbox run, store the mapping
if container_sdk_session_id and session.id != "pending":
    await self.session_manager.update_session_metadata(
        sandbox_sid, {"sandbox_sdk_session_id": container_sdk_session_id}
    )
```

### Change 6: Pass resume ID and workspace to sandbox on follow-up messages

**Files:** `computer/parachute/core/orchestrator.py`, `computer/parachute/core/sandbox.py`

**Changes:**
- For existing sandboxed sessions (not `is_new`), read `metadata.sandbox_sdk_session_id` from the session
- Pass it through to the container via the stdin JSON
- Pass the workspace path so the same workspace is mounted

```python
# orchestrator.py — sandbox path for existing sessions
sandbox_resume_id = None
if not is_new and session.metadata:
    meta = session.metadata if isinstance(session.metadata, dict) else {}
    sandbox_resume_id = meta.get("sandbox_sdk_session_id")

# Pass to sandbox run_agent
async for event in self._sandbox.run_agent(
    sandbox_config, message,
    workspace_path=workspace_path,
    resume_id=sandbox_resume_id,
):
```

```python
# sandbox.py — run_agent() passes resume to container via stdin
input_data = {"message": message}
if resume_id:
    input_data["resume"] = resume_id
proc.stdin.write(json.dumps(input_data).encode())
```

### Change 7: Handle Docker-unavailable on resume

**Files:** `computer/parachute/core/orchestrator.py`

**Changes:**
- When a session has `trust_level=sandboxed` but Docker is unavailable, emit a clear error and refuse to process rather than falling back to vault (which would lose conversation context)
- This is safer than a silent fallback that creates a disconnected conversation

```python
# orchestrator.py — Docker unavailable for existing sandboxed session
if effective_trust == "sandboxed" and not await self._sandbox.is_available():
    if not is_new:
        # Existing sandbox session can't fall back — transcript is in workspace
        yield {"type": "error", "error": "This sandboxed session requires Docker. Please start Docker to continue this conversation."}
        return
    else:
        # New session can fall back to vault
        effective_trust = "vault"
        yield {"type": "error", "error": "Docker not available -- falling back to vault trust level."}
```

### Change 8: Session metadata update helper

**Files:** `computer/parachute/core/session_manager.py`, `computer/parachute/db/database.py`

**Changes:**
- Add `update_session_metadata()` method that merges new keys into existing metadata JSON
- This is needed to store `sandbox_sdk_session_id` after the first container run

```python
# session_manager.py
async def update_session_metadata(self, session_id: str, updates: dict):
    """Merge updates into session metadata JSON."""
    session = await self.db.get_session(session_id)
    if not session:
        return
    metadata = session.metadata if isinstance(session.metadata, dict) else {}
    metadata.update(updates)
    await self.db.update_session_metadata(session_id, metadata)
```

## Acceptance Criteria

### Functional Requirements

- [x] First sandboxed message creates session with `trust_level=sandboxed` in DB
- [x] Second message finds the session, routes to sandbox, and maintains trust level
- [x] Conversation has full multi-turn continuity (AI remembers prior messages)
- [x] Workspace directory created at `vault/.workspaces/{sandbox_sid}/`
- [x] Transcript persists in workspace across container runs
- [x] Container SDK session ID stored in session metadata for resume
- [x] Docker-unavailable on existing sandbox session emits clear error (not silent fallback)

### Non-Functional Requirements

- [x] No access to other sessions' transcripts from inside the container
- [x] Workspace directory writable by container user
- [x] `--rm` flag preserved (container still cleaned up after each message)

## Dependencies & Risks

**Dependencies:**
- Docker must be available for sandboxed sessions (existing requirement)
- Claude Agent SDK must support `resume` parameter in `ClaudeAgentOptions`

**Risks:**
- **File permission mismatch**: Container user (UID 1000) writes to workspace, host user reads it. On macOS/Docker Desktop this works transparently. On Linux, may need `--user $(id -u):$(id -g)` flag.
- **CWD encoding**: Container WORKDIR is `/workspace`, encoded as `-workspace` in transcript path. This must be consistent across runs. Since we don't change WORKDIR, this is stable.
- **Race condition**: Two rapid messages to the same sandbox session could collide on container name. Existing `active_streams` dict provides some protection. Phase 1 accepts this limitation.

## Files Changed

| File | Change |
|------|--------|
| `computer/parachute/core/orchestrator.py` | Skip transcript check for sandboxed sessions, create workspace, capture SDK session ID, pass resume ID, handle Docker-unavailable for existing sessions |
| `computer/parachute/core/sandbox.py` | Accept workspace_path and resume_id params, mount workspace as HOME, pass resume via stdin JSON |
| `computer/parachute/docker/entrypoint.py` | Accept `resume` from stdin JSON, pass to ClaudeAgentOptions |
| `computer/parachute/core/session_manager.py` | Add `update_session_metadata()` method |
| `computer/parachute/db/database.py` | Add `update_session_metadata()` DB method (if not already present) |

## Test Plan

1. Start a sandboxed chat, send first message → verify DB row has `trust_level=sandboxed`
2. Send second message → verify logs show session found (no "Unknown session ID" warning)
3. Second message response should reference the first message content → conversation continuity works
4. Check `vault/.workspaces/{sid}/.claude/projects/-workspace/` has a `.jsonl` file
5. Stop Docker, send message to existing sandbox session → should get clear error, not silent fallback
6. Restart app → sandbox session should persist and resume correctly

## References

- Brainstorm: `docs/brainstorms/2026-02-08-sandbox-persistence-brainstorm.md`
- Orchestrator sandbox path: `computer/parachute/core/orchestrator.py:575-619`
- Session manager lookup: `computer/parachute/core/session_manager.py:98-201`
- Docker sandbox: `computer/parachute/core/sandbox.py`
- Container entrypoint: `computer/parachute/docker/entrypoint.py`
- Trust level resolution: `computer/parachute/core/orchestrator.py:555-573`
