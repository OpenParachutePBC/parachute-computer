---
title: "refactor: Workspace Trust Default & Persistent Docker Containers"
type: refactor
date: 2026-02-09
---

# Workspace Trust Default & Persistent Docker Containers

## Overview

Two interrelated changes to the workspace and Docker execution model:

1. **Workspace trust becomes a default, not a floor.** Currently workspace `trust_level` acts as a minimum restrictiveness -- sessions can only be made _more_ restrictive than the workspace. Changing so workspace trust is inherited as a default that sessions can freely override in either direction.

2. **Persistent Docker containers per workspace.** Currently each untrusted session gets a fresh ephemeral container (`docker run --rm`) that is destroyed after a single message exchange. Changing to long-lived containers per workspace that persist across messages, auto-stop after 15 minutes idle, and share the workspace working directory.

These changes are complementary: relaxing the trust floor makes persistent containers more important (sessions can move between trusted/untrusted freely), and persistent containers make untrusted mode much more practical (no cold-start penalty, SDK transcripts survive, multi-turn context works natively).

## Problem Statement

### Trust floor is too rigid

The current floor enforcement means:
- If a workspace is set to `untrusted`, no session in that workspace can be `trusted`. This prevents ad-hoc trusted sessions within an otherwise-sandboxed workspace.
- The UI disables trust options below the floor (lines 109-113 of `new_chat_sheet.dart`), confusing users who don't understand why some options are greyed out.
- The orchestrator enforces the floor silently (lines 548-552 of `orchestrator.py`), upgrading session trust without user feedback.
- There's no practical use case where a workspace _must_ prevent trusted sessions -- the user already has root access to the machine.

### Ephemeral containers are painful

The current `docker run --rm` model (line 183 of `sandbox.py`) has several problems:
- **Cold start every message**: Container startup adds latency on each message in a conversation.
- **No SDK transcripts**: The entrypoint comment at line 88-91 of `entrypoint.py` explicitly notes "We intentionally do NOT use resume here. The container has no access to SDK session transcripts." This forces synthetic transcript writing on the host (lines 756-760 of `orchestrator.py`) and context injection via `<conversation_history>` tags (lines 697-714 of `orchestrator.py`) -- both lossy workarounds.
- **No tool state**: Each container starts fresh with no filesystem state from prior turns. Files created by the agent in one message are lost before the next.
- **Resource waste**: Building mounts, writing env files, spinning up containers -- all repeated per-message.

## Proposed Solution

### 1. Trust as default

Rename `trust_level` to `default_trust_level` in `WorkspaceConfig`. New sessions inherit the workspace default but can freely override it to any value. The orchestrator no longer applies a floor -- it just uses the session's own trust level (or the workspace default if no session-level override).

### 2. Persistent containers per workspace

One Docker container per workspace slug, named `parachute-ws-{slug}`. Containers run detached (`docker run -d`), messages are sent via `docker exec`, and an idle timer auto-stops the container after 15 minutes of inactivity. A `ContainerManager` class manages the lifecycle.

```
Before (per-session, ephemeral):
  Session 1 → docker run --rm → container starts → message → container dies
  Session 2 → docker run --rm → container starts → message → container dies

After (per-workspace, persistent):
  Session 1 → ContainerManager.ensure_running("ws-slug")
            → docker exec (message 1)
            → docker exec (message 2)
  Session 2 → ContainerManager.ensure_running("ws-slug") [already running]
            → docker exec (message 3)
  [15 min idle] → ContainerManager stops container
```

---

## Technical Approach

### Part 1: Trust Model Changes (Default, Not Floor)

#### Phase 1.1: Rename field in Python models

**File: `computer/parachute/models/workspace.py`**

- [x] Line 73-76: Rename `trust_level` field to `default_trust_level`. Update the description from "Trust floor" to "Default trust level for new sessions". Keep type as `TrustLevelStr`.
  ```python
  default_trust_level: TrustLevelStr = Field(
      default="trusted",
      description="Default trust level for new sessions in this workspace",
  )
  ```
- [x] Line 110: Rename `trust_level` to `default_trust_level` in `WorkspaceCreate` with updated description.
- [x] Line 122: Rename `trust_level` to `default_trust_level` in `WorkspaceUpdate` with updated description.
- [x] Lines 94-102: Update `to_api_dict()` and `to_yaml_dict()` -- both use `model_dump()` which will pick up the rename automatically. No changes needed beyond verifying output.

**File: `computer/parachute/core/workspaces.py`**

- [x] Line 119: Update `create_workspace()` to use `create.default_trust_level` instead of `create.trust_level`.
- [x] Lines 135-155: `update_workspace()` uses generic `model_dump(exclude_none=True)` merging -- should work automatically with the rename. Verify.

**File: `computer/parachute/api/workspaces.py`**

- [x] No changes needed -- the API serialization flows through `to_api_dict()` which uses `model_dump()`. The JSON key changes from `trust_level` to `default_trust_level` automatically. Document this as a breaking API change.

#### Phase 1.2: Remove floor enforcement in orchestrator

**File: `computer/parachute/core/orchestrator.py`**

- [x] Lines 538-568 (trust resolution block): Replace the current three-step resolution (session -> workspace floor -> client override) with a simpler two-step resolution:
  1. Start with the session's stored trust level (from DB if resumed, or from client if new).
  2. If no session-level trust and workspace has `default_trust_level`, use it as the default.
  3. Client-provided `trust_level` param always takes priority (no floor check, no escalation prevention).

  Current logic (to replace):
  ```python
  # Lines 540-568: Three-step trust resolution
  session_trust = session.get_trust_level()

  if workspace_config and workspace_config.trust_level:
      workspace_trust = TrustLevel(ws_trust_str)
      if trust_rank(workspace_trust) > trust_rank(session_trust):
          # Floor enforcement -- REMOVE THIS
          session_trust = workspace_trust

  if trust_level:
      requested = TrustLevel(client_trust_str)
      if trust_rank(requested) >= trust_rank(session_trust):
          # Can only restrict, not escalate -- REMOVE THIS RESTRICTION
          session_trust = requested
      else:
          logger.warning("Client tried to escalate trust...")  # REMOVE
  ```

  New logic:
  ```python
  # Determine effective trust level
  # Priority: client param > session stored > workspace default > trusted
  if trust_level:
      # Client explicitly set trust level -- use it
      effective_trust = TrustLevel(trust_level).value
  elif session.trust_level:
      # Session has stored trust level (resumed session)
      effective_trust = session.get_trust_level().value
  elif workspace_config and workspace_config.default_trust_level:
      # Workspace provides default
      effective_trust = workspace_config.default_trust_level
  else:
      effective_trust = "trusted"
  ```

- [x] Remove the `trust_rank()` import from `orchestrator.py` if no longer used after this change. Currently imported at line 30.

#### Phase 1.3: Update Flutter Workspace model

**File: `app/lib/features/chat/models/workspace.dart`**

- [x] Line 9: Rename `trustLevel` to `defaultTrustLevel`.
- [x] Line 18: Update default value string.
- [x] Line 29: Update `fromJson` to read `default_trust_level` key (snake_case from server).
- [x] Line 44: Update `toJson` to write `default_trust_level` key.

#### Phase 1.4: Remove floor enforcement in Flutter UI

**File: `app/lib/features/chat/widgets/new_chat_sheet.dart`**

- [x] Lines 103-113: Remove the `_trustFloor` getter and `_isTrustAllowed()` method entirely. All trust levels are always selectable.
- [x] Lines 115-129 (`_selectWorkspace()`): Remove the floor enforcement logic that auto-upgrades trust when workspace is selected:
  ```dart
  // REMOVE these lines (124-127):
  final floor = TrustLevel.fromString(workspace.trustLevel);
  if (_selectedTrustLevel == null || _selectedTrustLevel!.index < floor.index) {
    _selectedTrustLevel = floor == TrustLevel.trusted ? null : floor;
  }
  ```
  Replace with: set `_selectedTrustLevel` to workspace default (but allow override):
  ```dart
  // Set default from workspace (user can still change freely)
  if (_selectedTrustLevel == null) {
    final wsTrust = TrustLevel.fromString(workspace.defaultTrustLevel);
    _selectedTrustLevel = wsTrust == TrustLevel.trusted ? null : wsTrust;
  }
  ```
- [x] Lines 492-539 (`_buildTrustChip()`): Remove the `isDisabled` logic entirely. The chip is always enabled. Remove the `Opacity` wrapper that dims disabled chips.

**File: `app/lib/features/chat/widgets/session_config_sheet.dart`**

- [x] Lines 260-284 (trust level `SegmentedButton`): The selector is already unconstrained (no floor logic here). No changes needed -- verify it works with the new workspace model.

**File: `app/lib/features/chat/widgets/workspace_dialog.dart`**

- [x] Lines 57-73 (`_WorkspaceForm`): Update the `DropdownButtonFormField` label from "Trust level" to "Default trust level" to clarify the semantics.
- [x] Line 117: Update `_trustLevel` default in `_CreateWorkspaceDialogState`.
- [x] Lines 162-186 (`_submit` in create): Update to use `defaultTrustLevel` in the service call.
- [x] Lines 268-290 (`_submit` in edit): Update to send `default_trust_level` key.

#### Phase 1.5: Workspace YAML migration

- [x] Existing workspace YAML files use `trust_level:`. Add a migration path in `_load_workspace()` (`core/workspaces.py` line 170-176) that reads either `default_trust_level` or `trust_level` (fallback) from the YAML:
  ```python
  def _load_workspace(slug: str, config_file: Path) -> WorkspaceConfig:
      with open(config_file) as f:
          data = yaml.safe_load(f) or {}
      data["slug"] = slug
      # Migrate old field name
      if "trust_level" in data and "default_trust_level" not in data:
          data["default_trust_level"] = data.pop("trust_level")
      return WorkspaceConfig(**data)
  ```

#### Phase 1.6: API backward compatibility

- [x] The workspace API response changes from `trust_level` to `default_trust_level`. Add a note in API response or handle in the Flutter client. Since the Flutter `Workspace.fromJson()` key changes, coordinate app + server deployment.
- [x] Option: Add a temporary compatibility alias in `WorkspaceConfig.to_api_dict()` that includes both keys during transition. (Handled via Flutter `fromJson` reading both keys as fallback.)

---

### Part 2: Persistent Docker Containers

#### Phase 2.1: New ContainerManager class

**New file: `computer/parachute/core/container_manager.py`**

- [ ] Create a `ContainerManager` class that manages workspace containers.

  Key design:
  ```
  ContainerManager
    _containers: dict[str, ContainerState]    # slug -> state
    _idle_timers: dict[str, asyncio.TimerHandle]  # slug -> timer
    _lock: asyncio.Lock                       # serialize container ops

  ContainerState
    container_id: str      # Docker container ID
    workspace_slug: str
    status: "running" | "stopped" | "starting"
    created_at: datetime
    last_activity: datetime
  ```

- [ ] `async def ensure_running(slug: str, config: AgentSandboxConfig) -> str` -- Returns container ID, starting one if needed:
  1. Check if container `parachute-ws-{slug}` exists and is running.
  2. If running: reset idle timer, return container ID.
  3. If stopped: `docker start parachute-ws-{slug}`, reset idle timer, return container ID.
  4. If not exists: `docker run -d` with workspace mounts, return container ID.

- [ ] `async def exec_message(slug: str, message: str, session_id: str, config: AgentSandboxConfig) -> AsyncGenerator[dict, None]` -- Execute a message in the workspace container:
  1. Call `ensure_running(slug, config)` to get container ID.
  2. Write message JSON to a temp file, copy into container.
  3. `docker exec -i {container_id} python /workspace/entrypoint.py < input.json`
  4. Stream stdout lines as JSONL events (same as current `run_agent`).
  5. Reset idle timer after exec completes.

- [ ] `async def stop_container(slug: str)` -- Stop and optionally remove a container:
  1. `docker stop parachute-ws-{slug}` (graceful, 10s timeout).
  2. Update `_containers` state.
  3. Cancel idle timer.

- [ ] `async def stop_all()` -- Stop all managed containers (for server shutdown).

- [ ] `_reset_idle_timer(slug: str)` -- Cancel existing timer, schedule new one for 15 minutes:
  ```python
  def _reset_idle_timer(self, slug: str):
      if slug in self._idle_timers:
          self._idle_timers[slug].cancel()
      loop = asyncio.get_event_loop()
      self._idle_timers[slug] = loop.call_later(
          900,  # 15 minutes
          lambda: asyncio.ensure_future(self.stop_container(slug)),
      )
  ```

#### Phase 2.2: Container naming and lifecycle

- [ ] Container naming convention: `parachute-ws-{slug}` where slug is the workspace slug (already validated as `[a-z0-9-]+` by `_SLUG_PATTERN` in `core/workspaces.py` line 30).
- [ ] Docker label scheme for management:
  ```
  --label parachute.workspace={slug}
  --label parachute.managed=true
  ```
- [ ] On server startup: scan for orphaned `parachute-ws-*` containers and adopt them into `ContainerManager._containers` or stop them (configurable).

#### Phase 2.3: Build docker run args for persistent containers

**File: `computer/parachute/core/sandbox.py`**

- [ ] Refactor `_build_run_args()` (lines 172-259) to support both modes:
  - Keep the existing method signature but add a `persistent: bool = False` parameter.
  - When `persistent=True`:
    - Use `docker run -d` instead of `docker run --rm -i` (line 183-184).
    - Use `--name parachute-ws-{slug}` instead of `parachute-sandbox-{session_id[:8]}` (line 186).
    - Add `--restart unless-stopped` for resilience.
    - Use `tail -f /dev/null` as the entrypoint (keep container alive) instead of `python /workspace/entrypoint.py`.
    - Mount the workspace working directory as RW (same as today).
    - Mount Claude SDK session storage directory so transcripts persist: `-v parachute-ws-{slug}-claude:/home/sandbox/.claude`
  - When `persistent=False` (default): Keep current behavior for backward compatibility.

- [ ] Add a new method `_build_exec_args(container_id: str, config: AgentSandboxConfig) -> list[str]`:
  ```python
  def _build_exec_args(self, container_id: str, config: AgentSandboxConfig) -> list[str]:
      return [
          "docker", "exec", "-i",
          "-e", f"PARACHUTE_SESSION_ID={config.session_id}",
          "-e", f"PARACHUTE_AGENT_TYPE={config.agent_type}",
          container_id,
          "python", "/workspace/entrypoint.py",
      ]
  ```
  Note: Environment variables like `CLAUDE_CODE_OAUTH_TOKEN` and `PARACHUTE_CWD` are set at container creation time (via `docker run -d`), so they persist across execs. Session-specific variables are passed per-exec via `-e` flags.

#### Phase 2.4: Docker volume for SDK transcripts

- [ ] Create a named Docker volume per workspace: `parachute-ws-{slug}-claude`. Mount at `/home/sandbox/.claude` inside the container. This allows the SDK to write and read JSONL transcript files, enabling native `--resume` for multi-turn conversations.
- [ ] With transcripts persisting inside the container:
  - The entrypoint (`entrypoint.py` line 88-91) can now use `resume` when a session_id is provided.
  - The orchestrator no longer needs `<conversation_history>` context injection for sandbox sessions (lines 697-714 of `orchestrator.py`).
  - The orchestrator no longer needs `write_sandbox_transcript()` for synthetic host transcripts (lines 756-760 of `orchestrator.py`).

#### Phase 2.5: Update entrypoint for exec mode

**File: `computer/parachute/docker/entrypoint.py`**

- [ ] Add support for `--resume` when running under `docker exec`:
  ```python
  # If we have a session_id and transcripts exist, try to resume
  resume_id = None
  if session_id:
      # Check if SDK has a transcript for this session
      # (transcripts are in /home/sandbox/.claude/projects/)
      claude_dir = Path.home() / ".claude" / "projects"
      if claude_dir.exists():
          for project_dir in claude_dir.iterdir():
              if (project_dir / f"{session_id}.jsonl").exists():
                  resume_id = session_id
                  break

  if resume_id:
      options_kwargs["resume"] = resume_id
  ```
- [ ] The CWD handling (lines 46-51) remains the same -- `PARACHUTE_CWD` is set at container creation time.

#### Phase 2.6: Update orchestrator sandbox routing

**File: `computer/parachute/core/orchestrator.py`**

- [ ] Lines 664-777 (sandbox routing block): Replace the current flow with `ContainerManager`:

  Current flow (to replace):
  ```python
  if effective_trust == "untrusted":
      if await self._sandbox.is_available():
          sandbox_config = AgentSandboxConfig(...)
          async for event in self._sandbox.run_agent(sandbox_config, sandbox_message):
              ...
  ```

  New flow:
  ```python
  if effective_trust == "untrusted":
      if await self._sandbox.is_available():
          sandbox_sid = session.id if session.id != "pending" else str(uuid.uuid4())
          sandbox_config = AgentSandboxConfig(
              session_id=sandbox_sid,
              agent_type=agent.type.value if agent.type else "chat",
              allowed_paths=sandbox_paths,
              network_enabled=True,
              mcp_servers=resolved_mcps,
              working_directory=sandbox_wd,
          )

          # Determine workspace slug for container routing
          container_slug = workspace_id or "default"

          async for event in self._container_manager.exec_message(
              slug=container_slug,
              message=actual_message,
              session_id=sandbox_sid,
              config=sandbox_config,
          ):
              # ... event processing (same as current, but without
              # conversation_history injection or synthetic transcript writing)
  ```

- [ ] Remove the `<conversation_history>` injection block (lines 697-714). With persistent containers, the SDK can resume sessions natively.
- [ ] Remove the `write_sandbox_transcript()` call (lines 756-760). The SDK inside the container writes its own transcripts to the persistent volume.
- [ ] Keep the session finalization logic (lines 741-752) -- the orchestrator still needs to track sessions in SQLite.
- [ ] The `is_new` check for resume behavior changes: for persistent containers, `is_new` determines whether to pass `resume` to the entrypoint via the session_id, not whether to inject conversation history.

#### Phase 2.7: Initialize ContainerManager in orchestrator

**File: `computer/parachute/core/orchestrator.py`**

- [ ] Lines 177-193 (`__init__`): Add `ContainerManager` initialization alongside the existing `DockerSandbox`:
  ```python
  from parachute.core.container_manager import ContainerManager

  self._container_manager = ContainerManager(
      vault_path=vault_path,
      sandbox=self._sandbox,  # Reuse Docker availability checks
      idle_timeout=900,  # 15 minutes
  )
  ```

- [ ] Keep `self._sandbox` for Docker availability checks (`is_available()`, `image_exists()`, `health_info()`). The `ContainerManager` delegates to it.

#### Phase 2.8: Server shutdown cleanup

**File: `computer/parachute/server.py`**

- [ ] Add a shutdown handler that calls `container_manager.stop_all()`:
  ```python
  @app.on_event("shutdown")
  async def shutdown_event():
      orchestrator = app.state.orchestrator
      if hasattr(orchestrator, '_container_manager'):
          await orchestrator._container_manager.stop_all()
  ```

#### Phase 2.9: Workspace deletion cleanup

**File: `computer/parachute/api/workspaces.py`**

- [ ] Lines 66-93 (`delete_workspace`): Before deleting the workspace directory, stop and remove the workspace container:
  ```python
  @router.delete("/{slug}")
  async def delete_workspace(request: Request, slug: str):
      # ... existing validation ...

      # Stop workspace container if running
      orchestrator = request.app.state.orchestrator
      if hasattr(orchestrator, '_container_manager'):
          await orchestrator._container_manager.stop_container(slug, remove=True)
          # Also remove the Docker volume
          # docker volume rm parachute-ws-{slug}-claude

      # ... existing session unlinking and directory deletion ...
  ```

#### Phase 2.10: Non-workspace untrusted sessions

- [ ] Sessions without a workspace_id that are untrusted need a container too. Use a fallback slug like `"_default"` or generate one from the session_id. Options:
  - **Option A**: Route to a shared `parachute-ws-_default` container. Simple, but sessions share filesystem state.
  - **Option B**: Fall back to ephemeral containers (current behavior) for workspace-less untrusted sessions.
  - **Recommendation**: Option B -- keep ephemeral for workspace-less sessions, persistent for workspace sessions. This is the simplest migration path and avoids cross-session contamination.

---

### Part 3: Transcript Handling

#### Phase 3.1: SDK transcripts inside persistent containers

- [ ] With named volume `parachute-ws-{slug}-claude` mounted at `/home/sandbox/.claude`, the SDK writes JSONL transcripts to `/home/sandbox/.claude/projects/{encoded-cwd}/{session-id}.jsonl`.
- [ ] The entrypoint can now pass `resume=session_id` to the SDK, enabling native multi-turn conversations without context injection.
- [ ] The host-side `session_manager.write_sandbox_transcript()` (called at orchestrator line 757-760) becomes unnecessary for persistent containers. Keep it for ephemeral (workspace-less) containers.

#### Phase 3.2: Host transcript access

- [ ] The host needs to read sandbox transcripts for the `/api/chat/{id}/transcript` endpoint (`orchestrator.py` lines 1323-1458). Two options:
  - **Option A**: `docker cp` from the named volume when the transcript endpoint is called.
  - **Option B**: Mount the volume to a host path and read directly.
  - **Recommendation**: Option A -- use `docker cp` on demand. The volume path on the host is Docker-internal and platform-specific. `docker cp parachute-ws-{slug}:/home/sandbox/.claude/projects/ /tmp/transcript-extract/` extracts files reliably.

- [ ] Update `get_session_transcript()` (lines 1323-1458) to check both host-side paths and container volumes:
  ```python
  # 1. Check host-side paths (existing logic, lines 1352-1376)
  # 2. If not found, try extracting from container volume
  if not session_file and session.trust_level == "untrusted" and session.workspace_id:
      session_file = await self._extract_container_transcript(
          workspace_slug=session.workspace_id,
          session_id=session_id,
      )
  ```

#### Phase 3.3: Remove synthetic transcript writing for persistent containers

- [ ] In the orchestrator sandbox routing (lines 740-761), add a condition:
  ```python
  # Only write synthetic transcripts for ephemeral containers
  # Persistent containers have native SDK transcripts in the volume
  if not workspace_id:  # ephemeral container
      self.session_manager.write_sandbox_transcript(...)
  ```

---

### Part 4: Error Handling

#### Phase 4.1: Container crash recovery

- [ ] `ContainerManager.ensure_running()` should detect containers in unexpected states:
  - Container exists but is in "exited" status with non-zero exit code: remove and recreate.
  - Container exists but health check fails: restart.
  - `docker exec` fails with container-not-running error: retry after `ensure_running()`.

- [ ] Add retry logic to `exec_message()`:
  ```python
  async def exec_message(self, slug, message, session_id, config):
      for attempt in range(2):
          try:
              container_id = await self.ensure_running(slug, config)
              async for event in self._exec_in_container(container_id, message, session_id, config):
                  yield event
              return
          except ContainerNotRunningError:
              if attempt == 0:
                  logger.warning(f"Container for {slug} died, recreating...")
                  await self.stop_container(slug, remove=True)
                  continue
              raise
  ```

#### Phase 4.2: Docker unavailable

- [ ] No change from current behavior (lines 774-781 of `orchestrator.py`): if Docker is not available and trust is `untrusted`, return an error. Never silently degrade to trusted.

#### Phase 4.3: Workspace deletion while container is running

- [ ] The delete endpoint (Phase 2.9) stops the container before deleting. If the container has active execs, they will be killed when the container stops. The orchestrator will receive broken pipe / EOF and emit an error event to the client.
- [ ] Add a check: if the workspace has active streams (`orchestrator.active_streams`), warn or block deletion:
  ```python
  # Check for active sessions in this workspace
  active = [sid for sid in orchestrator.get_active_stream_ids()
            if sid in workspace_session_ids]
  if active:
      raise HTTPException(
          status_code=409,
          detail=f"Workspace has {len(active)} active session(s). Stop them first.",
      )
  ```

#### Phase 4.4: Container resource cleanup

- [ ] Add a periodic cleanup task (e.g., every 30 minutes) to `ContainerManager` that:
  1. Lists all `parachute-ws-*` containers.
  2. Compares against known workspace slugs.
  3. Removes containers for deleted workspaces.
  4. Removes orphaned Docker volumes.

- [ ] Add a `parachute containers` CLI command:
  ```bash
  parachute containers list     # Show managed containers
  parachute containers stop     # Stop all containers
  parachute containers prune    # Remove stopped containers + orphaned volumes
  ```

#### Phase 4.5: Concurrent exec protection

- [ ] Multiple sessions in the same workspace may send messages simultaneously. Each `docker exec` runs in its own process inside the container. The Claude SDK inside the container handles this correctly (separate session files), but filesystem access could conflict.
- [ ] Add a per-workspace semaphore in `ContainerManager` to limit concurrent execs (default: 3). This prevents resource exhaustion inside the container:
  ```python
  _exec_semaphores: dict[str, asyncio.Semaphore]  # slug -> semaphore

  async def exec_message(self, slug, ...):
      sem = self._exec_semaphores.setdefault(slug, asyncio.Semaphore(3))
      async with sem:
          ...
  ```

---

## Migration Path

### Server-side migration

1. Deploy trust model changes first (Part 1). This is backward compatible -- the only visible change is workspace config responding with `default_trust_level` instead of `trust_level`.
2. Deploy persistent containers (Part 2). Old sessions continue to work: workspace-less sessions use ephemeral containers, workspace sessions use persistent containers.
3. Existing YAML workspace configs get migrated on read via the `_load_workspace()` fallback (Phase 1.5).

### Client-side migration

1. Update Flutter `Workspace` model to read `default_trust_level` (with `trust_level` fallback for older servers).
2. Remove floor enforcement from UI.
3. No DB migration needed -- trust level storage is in session records, which are not changing.

### Rollback plan

- Trust model: If reverted, the server accepts both field names. Add the `trust_level` alias back to `WorkspaceConfig` temporarily.
- Persistent containers: `ContainerManager` can be bypassed by routing through `DockerSandbox.run_agent()` directly. Keep the old path behind a feature flag initially:
  ```python
  if settings.persistent_containers and workspace_id:
      # Use ContainerManager
  else:
      # Use DockerSandbox.run_agent() (old path)
  ```

---

## Acceptance Criteria

### Trust model (Part 1)

- [x] `WorkspaceConfig.default_trust_level` replaces `trust_level` in Python model
- [x] `Workspace.defaultTrustLevel` replaces `trustLevel` in Flutter model
- [x] Workspace API returns `default_trust_level` key
- [x] Orchestrator uses workspace trust as default, not floor -- a `trusted` session in an `untrusted` workspace runs bare metal
- [x] All trust chips in new chat sheet are always enabled (no greyed-out state)
- [x] Workspace dialog label reads "Default trust level"
- [x] Existing YAML configs with `trust_level:` are read correctly
- [x] Session config sheet allows free trust level selection regardless of workspace

### Persistent containers (Part 2)

- [ ] Untrusted workspace sessions use `docker run -d` + `docker exec` instead of `docker run --rm`
- [ ] Container name follows `parachute-ws-{slug}` convention
- [ ] Second message to same workspace reuses running container (no cold start)
- [ ] Container auto-stops after 15 minutes idle
- [ ] `docker exec` after auto-stop triggers container restart
- [ ] SDK transcripts persist in named Docker volume
- [ ] Entrypoint uses `--resume` for existing sessions in persistent containers
- [ ] No `<conversation_history>` injection for persistent container sessions
- [ ] No `write_sandbox_transcript()` for persistent container sessions
- [ ] Workspace deletion stops and removes workspace container + volume
- [ ] Server shutdown stops all managed containers
- [ ] Workspace-less untrusted sessions still use ephemeral containers
- [ ] Concurrent execs limited by semaphore (default: 3 per workspace)

### Error handling (Part 4)

- [ ] Container crash during exec: detected, container recreated, retry attempted
- [ ] Docker unavailable: clear error (no silent degradation)
- [ ] Workspace deleted with active sessions: 409 Conflict response
- [ ] Orphaned containers cleaned up periodically
- [ ] CLI command `parachute containers` available for manual management

---

## Files Modified

| File | Repo | Phase | Changes |
|------|------|-------|---------|
| `parachute/models/workspace.py` | computer | 1.1 | Rename `trust_level` -> `default_trust_level` |
| `parachute/core/workspaces.py` | computer | 1.1, 1.5 | Update field references, YAML migration |
| `parachute/api/workspaces.py` | computer | 1.6, 2.9 | API compat, container cleanup on delete |
| `parachute/core/orchestrator.py` | computer | 1.2, 2.6, 2.7 | Trust resolution, container routing, init |
| `parachute/core/sandbox.py` | computer | 2.3 | Persistent mode in `_build_run_args`, exec args |
| `parachute/core/container_manager.py` | computer | 2.1 | **NEW** -- ContainerManager class |
| `parachute/docker/entrypoint.py` | computer | 2.5 | Resume support for persistent containers |
| `parachute/server.py` | computer | 2.8 | Shutdown handler |
| `parachute/cli.py` | computer | 4.4 | `parachute containers` subcommand |
| `features/chat/models/workspace.dart` | app | 1.3 | Rename field |
| `features/chat/widgets/new_chat_sheet.dart` | app | 1.4 | Remove floor enforcement |
| `features/chat/widgets/session_config_sheet.dart` | app | 1.4 | Verify unconstrained selector |
| `features/chat/widgets/workspace_dialog.dart` | app | 1.4 | Update label, field name |

## Dependencies & Prerequisites

- Docker installed for untrusted sessions (unchanged)
- Trust model simplification plan (completed) -- binary model is prerequisite
- `/vault` symlink exists (from prior plan)

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking API change (`trust_level` -> `default_trust_level`) | Flutter client fails to parse workspace | Dual-key transition: include both keys temporarily |
| Persistent container accumulates stale state | Unexpected agent behavior | Named volume for `.claude/` only; workspace dir is still mounted from host (fresh reads) |
| Container idle timeout too aggressive | Cold starts during active usage | 15 min default with configurable `settings.container_idle_timeout` |
| Container idle timeout too lenient | Resource waste | CLI `parachute containers prune` for manual cleanup |
| Named volume grows unbounded | Disk full | Add volume size monitoring to `parachute doctor` |
| Concurrent execs overwhelm container | OOM/CPU | Per-workspace semaphore (default 3), container memory/CPU limits unchanged |
| `docker exec` startup still slow | Latency per message | Acceptable: exec latency is ~200ms vs ~3s for full container start |
| Removing trust floor allows users to bypass sandbox | Security concern | Users already have root access. Trust is a convenience default, not a security boundary against the local user |

## References

### Internal References

- Trust model simplification plan: `docs/plans/2026-02-09-refactor-trust-model-simplification-plan.md`
- Workspace model: `computer/parachute/models/workspace.py:64-102`
- Orchestrator trust resolution: `computer/parachute/core/orchestrator.py:538-568`
- Orchestrator sandbox routing: `computer/parachute/core/orchestrator.py:664-777`
- Sandbox container creation: `computer/parachute/core/sandbox.py:172-259`
- Sandbox agent execution: `computer/parachute/core/sandbox.py:261-351`
- Docker entrypoint: `computer/parachute/docker/entrypoint.py:1-161`
- Capability filter trust_rank: `computer/parachute/core/capability_filter.py:20-31`
- Workspace storage: `computer/parachute/core/workspaces.py:69-184`
- Workspace API: `computer/parachute/api/workspaces.py:1-127`
- Flutter workspace model: `app/lib/features/chat/models/workspace.dart:1-106`
- Flutter trust level enum: `app/lib/features/settings/models/trust_level.dart:1-45`
- New chat sheet floor enforcement: `app/lib/features/chat/widgets/new_chat_sheet.dart:103-129`
- Session config sheet: `app/lib/features/chat/widgets/session_config_sheet.dart:1-571`
- Workspace dialog: `app/lib/features/chat/widgets/workspace_dialog.dart:1-316`
