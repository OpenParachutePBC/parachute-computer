---
title: "Persistent Docker Containers per Workspace"
type: feat
date: 2026-02-16
issue: "#33"
labels: [brainstorm, computer, P1]
deepened: 2026-02-16
---

# Persistent Docker Containers per Workspace

## Enhancement Summary

**Deepened on:** 2026-02-16
**Review agents used:** agent-native-architecture, python-reviewer, security-sentinel, architecture-strategist, performance-oracle, parachute-conventions-reviewer, code-simplicity-reviewer, best-practices-researcher

### Key Improvements from Review

1. **Simplified to 4 phases** (was 8) — cut CLI commands, REST endpoints, SandboxConfig wiring, and health additions for MVP. These are YAGNI until needed.
2. **`--init` flag required** — Prevents zombie process accumulation from completed `docker exec` sessions. `tini` as PID 1 reaps children and forwards signals.
3. **Stdin JSON protocol for per-session data** — `docker exec` cannot mount volumes or use `--env-file` (pre-Docker 26.0). Pass capabilities, system_prompt, and secrets via enriched stdin JSON payload.
4. **Security hardening** — `--cap-drop ALL`, `--security-opt no-new-privileges`, `--pids-limit 100`, `--read-only` for entrypoint paths.
5. **Per-slug asyncio.Lock** — Prevents race conditions when concurrent requests trigger `get_or_create` for the same workspace.
6. **Constructor injection** — ContainerManager passed to Orchestrator via constructor, not monkey-patched as private attribute.
7. **Docker labels** for container discovery — Rich metadata querying without parsing container names.

### Critical Corrections from Review

- **`docker exec --env-file` doesn't exist** before Docker 26.0 — use `-e` flags for non-sensitive vars and stdin for secrets (OAuth token)
- **`docker exec` cannot add volume mounts** — capabilities JSON and system_prompt must be piped via stdin, not mounted as temp files
- **Cross-session privilege escalation risk** — Persistent filesystem means one session can plant malicious files (PATH hijack, .bashrc poisoning). Mitigated by read-only mounts for entrypoint/system paths.
- **In-memory `_containers` dict is fragile** — Use `docker inspect` as source of truth, cache as optimization only

---

## Overview

Replace ephemeral per-message Docker containers with persistent per-workspace containers for untrusted sessions. Currently every untrusted message spins up a fresh container (`docker run --rm`), executes one message, and destroys the container. This wastes startup time, loses all in-container state (installed packages, file changes), and prevents multi-turn workflows from building on prior work.

After this change, each workspace gets one long-running Docker container. Sessions connect via `docker exec`, sharing the container's filesystem and accumulated state. Containers are created lazily on first use and persist across server restarts.

## Problem Statement

### Current Behavior (Ephemeral)

```
Message 1 → docker run --rm → container starts → SDK query → response → container destroyed
Message 2 → docker run --rm → container starts → SDK query → response → container destroyed
Message 3 → docker run --rm → container starts → SDK query → response → container destroyed
```

Each message:
1. Creates a fresh container (2-5s startup overhead)
2. Passes the message via stdin, reads JSONL from stdout
3. Destroys the container on exit (`--rm` flag)
4. Loses all in-container state

Multi-turn sessions inject prior conversation history into the prompt as a workaround (orchestrator.py lines 735-753), but the agent can't resume installed packages, modified files, or SDK session state.

### Proposed Behavior (Persistent)

```
First message  → docker run -d --init → container running
Message 1      → docker exec -i → entrypoint runs → response → process exits, container stays
Message 2      → docker exec -i → entrypoint runs → response → process exits, container stays
...
Workspace deleted or manual stop → container removed
```

## Proposed Solution

### Execution Model: `docker exec` per Session

The container runs `tini` as PID 1 (via `--init` flag) supervising `sleep infinity` as PID 2. Each session invocation uses `docker exec -i` to spawn the existing entrypoint script as a separate process inside the running container. This:

- Preserves the existing entrypoint logic (read stdin, run SDK, emit JSONL)
- Naturally isolates concurrent sessions (separate processes, separate stdin/stdout pipes)
- Avoids building a custom message daemon inside the container
- Passes fresh env vars and config per-exec (solves token rotation)
- Reaps zombie processes from completed exec sessions (tini handles this)

### Architecture

```
DockerSandbox (extended — single class, two modes)
├── is_available() → Docker check (existing, unchanged)
├── image_exists() → Image check (existing, unchanged)
├── run_agent(config, message) → ephemeral path (existing, for workspace-less sessions)
├── run_persistent(workspace_slug, config, message) → AsyncGenerator[dict]  # NEW
├── ensure_container(workspace_slug, config) → str  # NEW — get or create
├── stop_container(workspace_slug) → None  # NEW
└── reconcile() → None  # NEW — server startup discovery

Orchestrator (modified)
├── __init__ receives DockerSandbox (already does)
├── Routes untrusted+workspace sessions through run_persistent
└── Falls back to run_agent for workspace-less sessions
```

### Research Insight: Extend DockerSandbox, Don't Create New Class

The simplicity reviewer and architecture strategist both recommended against creating a separate `ContainerManager` class. The persistent container logic shares 80% of DockerSandbox's code (mount building, env construction, JSONL streaming, timeout handling). Adding methods to DockerSandbox avoids:
- Duplicated mount/env logic
- A new class that needs its own Docker availability checks
- Constructor injection complexity (Orchestrator already has `self._sandbox`)
- Shared state coordination between two classes

## Technical Approach

### Phase 1: Extend DockerSandbox with Persistent Container Support

**Modified file: `computer/parachute/core/sandbox.py`**

Add persistent container methods to the existing `DockerSandbox` class.

```python
import asyncio
from collections import defaultdict

class DockerSandbox:
    # ... existing code ...

    def __init__(self, vault_path: Path, claude_token: Optional[str] = None):
        # ... existing init ...
        self._slug_locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

    # --- Persistent container methods ---

    async def ensure_container(
        self, workspace_slug: str, config: AgentSandboxConfig
    ) -> str:
        """Ensure a persistent container is running for this workspace.

        Returns the container name. Creates the container lazily on first call.
        Thread-safe via per-slug asyncio.Lock.
        """
        container_name = f"parachute-ws-{workspace_slug}"

        async with self._slug_locks[workspace_slug]:
            # Check if already running via docker inspect (source of truth)
            status = await self._inspect_status(container_name)

            if status == "running":
                return container_name
            elif status in ("exited", "created"):
                await self._start_container(container_name)
                return container_name
            elif status is not None:
                # Bad state (dead, removing, etc.) — force remove and recreate
                await self._remove_container(container_name)

            # Create new container
            await self._create_persistent_container(
                container_name, workspace_slug, config
            )
            return container_name

    async def _inspect_status(self, container_name: str) -> Optional[str]:
        """Get container status via docker inspect. Returns None if not found."""
        proc = await asyncio.create_subprocess_exec(
            "docker", "inspect", "-f", "{{.State.Status}}", container_name,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode != 0:
            return None
        return stdout.decode().strip()

    async def _create_persistent_container(
        self, container_name: str, workspace_slug: str, config: AgentSandboxConfig
    ) -> None:
        """Create and start a persistent container for a workspace."""
        args = [
            "docker", "run", "-d",
            "--init",  # tini as PID 1 — reaps zombies, forwards signals
            "--name", container_name,
            "--memory", CONTAINER_MEMORY_LIMIT,
            "--cpus", CONTAINER_CPU_LIMIT,
            # Security hardening
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--pids-limit", "100",
            # Labels for discovery
            "--label", "app=parachute",
            "--label", f"workspace={workspace_slug}",
        ]

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])

        # Volume mounts (reuse existing _build_mounts)
        args.extend(self._build_mounts(config))

        # Image + keep-alive command
        args.extend([SANDBOX_IMAGE, "sleep", "infinity"])

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"Failed to create container {container_name}: {stderr.decode()}"
            )
        logger.info(f"Created persistent container {container_name} for workspace {workspace_slug}")

    async def run_persistent(
        self,
        workspace_slug: str,
        config: AgentSandboxConfig,
        message: str,
    ) -> AsyncGenerator[dict, None]:
        """Run an agent session in a persistent workspace container.

        Uses docker exec to spawn a process in the running container.
        Per-session data (capabilities, system_prompt, token) is passed
        via enriched stdin JSON payload since docker exec cannot mount volumes.
        """
        if not await self.is_available():
            raise RuntimeError("Docker not available for sandboxed execution")
        if not await self.image_exists():
            raise RuntimeError(f"Sandbox image '{SANDBOX_IMAGE}' not found.")

        container_name = await self.ensure_container(workspace_slug, config)

        # Build exec args — env vars for non-sensitive config only
        exec_args = [
            "docker", "exec", "-i",
            "-e", f"PARACHUTE_SESSION_ID={config.session_id}",
            "-e", f"PARACHUTE_AGENT_TYPE={config.agent_type}",
        ]
        if config.working_directory:
            exec_args.extend(["-e", f"PARACHUTE_CWD={config.working_directory}"])
        if config.model:
            exec_args.extend(["-e", f"PARACHUTE_MODEL={config.model}"])
        if config.mcp_servers is not None:
            mcp_names = ",".join(config.mcp_servers.keys())
            exec_args.extend(["-e", f"PARACHUTE_MCP_SERVERS={mcp_names}"])

        exec_args.extend([
            container_name,
            "python", "/workspace/entrypoint.py",
        ])

        proc = await asyncio.create_subprocess_exec(
            *exec_args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        try:
            if proc.stdin is None or proc.stdout is None:
                yield {"type": "error", "message": "Failed to open pipes to container"}
                return

            # Build enriched stdin payload — includes secrets and per-session data
            # that can't be passed via docker exec volume mounts
            stdin_payload = {"message": message}
            if self.claude_token:
                stdin_payload["claude_token"] = self.claude_token
            if config.system_prompt:
                stdin_payload["system_prompt"] = config.system_prompt

            # Capabilities
            capabilities = {}
            if config.plugin_dirs:
                capabilities["plugin_dirs"] = [
                    f"/plugins/plugin-{i}" for i in range(len(config.plugin_dirs))
                    if config.plugin_dirs[i].is_dir()
                ]
            if config.mcp_servers:
                capabilities["mcp_servers"] = config.mcp_servers
            if config.agents:
                capabilities["agents"] = config.agents
            if capabilities:
                stdin_payload["capabilities"] = capabilities

            proc.stdin.write(json.dumps(stdin_payload).encode() + b"\n")
            await proc.stdin.drain()
            proc.stdin.close()

            # Stream JSONL from stdout with timeout (same pattern as run_agent)
            deadline = time.time() + config.timeout_seconds
            timed_out = False
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    line = await asyncio.wait_for(
                        proc.stdout.readline(),
                        timeout=min(remaining, 180),
                    )
                except asyncio.TimeoutError:
                    timed_out = True
                    break
                if not line:
                    break
                try:
                    yield json.loads(line.decode().strip())
                except json.JSONDecodeError:
                    logger.debug(f"Non-JSON from persistent sandbox: {line.decode().strip()}")

            if timed_out:
                logger.error(f"Persistent sandbox timed out for session {config.session_id}")
                proc.kill()
                yield {"type": "error", "message": "Sandbox execution timed out"}
                return

            try:
                await asyncio.wait_for(proc.wait(), timeout=10)
            except asyncio.TimeoutError:
                proc.kill()

            if proc.returncode and proc.returncode != 0:
                stderr_data = b""
                if proc.stderr:
                    stderr_data = await proc.stderr.read()
                logger.error(f"Persistent sandbox exited {proc.returncode}: {stderr_data.decode()}")

                # Exit code 137 = OOM killed — recreate container
                if proc.returncode == 137:
                    logger.warning(f"Container {container_name} OOM killed, will recreate on next use")
                    await self._remove_container(container_name)
                    yield {"type": "error", "message": "Container ran out of memory. It will be recreated on next use."}
                else:
                    yield {"type": "error", "message": f"Sandbox error (exit {proc.returncode})"}

        except OSError as e:
            logger.error(f"Failed to exec in persistent sandbox: {e}")
            yield {"type": "error", "message": f"Failed to exec in sandbox: {e}"}
        finally:
            # Ensure exec process is terminated if still running
            if proc.returncode is None:
                try:
                    proc.kill()
                    await proc.wait()
                except ProcessLookupError:
                    pass

    async def stop_container(self, workspace_slug: str) -> None:
        """Stop and remove a workspace's persistent container."""
        container_name = f"parachute-ws-{workspace_slug}"
        await self._stop_container(container_name)
        await self._remove_container(container_name)

    async def _start_container(self, container_name: str) -> None:
        proc = await asyncio.create_subprocess_exec(
            "docker", "start", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"Failed to start {container_name}: {stderr.decode()}")

    async def _stop_container(self, container_name: str) -> None:
        proc = await asyncio.create_subprocess_exec(
            "docker", "stop", "-t", "10", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await asyncio.wait_for(proc.wait(), timeout=15)

    async def _remove_container(self, container_name: str) -> None:
        proc = await asyncio.create_subprocess_exec(
            "docker", "rm", "-f", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

    async def reconcile(self) -> None:
        """Discover existing parachute-ws-* containers on server startup."""
        proc = await asyncio.create_subprocess_exec(
            "docker", "ps", "-a",
            "--filter", "label=app=parachute",
            "--format", "{{.Names}}\t{{.Status}}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode != 0:
            logger.warning("Failed to discover existing containers")
            return

        count = 0
        for line in stdout.decode().strip().split("\n"):
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 1 and parts[0].startswith("parachute-ws-"):
                count += 1
        logger.info(f"Reconciled {count} existing workspace containers")
```

### Research Insights for Phase 1

**Concurrency Safety:**
- `defaultdict(asyncio.Lock)` provides per-slug locks — concurrent requests for the same workspace serialize through `get_or_create`, but different workspaces proceed in parallel
- `docker inspect` is the source of truth for container status, not an in-memory dict

**Zombie Prevention:**
- `--init` flag adds `tini` as PID 1 which reaps orphaned child processes from completed `docker exec` sessions
- Without `--init`, `sleep infinity` as PID 1 does NOT reap zombies — they accumulate over time

**Performance Comparison (from best-practices research):**
| Aspect | `docker run --rm` (current) | `docker exec` (proposed) |
|--------|---------------------------|-------------------------|
| Startup latency | 1-3 seconds | ~50ms |
| I/O isolation | N/A (one process) | Each exec gets own pipes |
| Concurrent sessions | Separate containers | Multiple execs in one container |

**OOM Handling:**
- Exit code 137 from `docker exec` indicates the OOM killer terminated a process
- Container should be force-removed and recreated on next use

### Phase 2: Dockerfile Changes

**Modified file: `computer/parachute/docker/Dockerfile.sandbox`**

Remove `ENTRYPOINT` so `CMD` provides the default for persistent mode:

```dockerfile
# Remove ENTRYPOINT — persistent containers use sleep infinity as default
# Ephemeral mode passes entrypoint explicitly: docker run ... python /workspace/entrypoint.py
# Persistent mode execs explicitly: docker exec -i ... python /workspace/entrypoint.py
CMD ["sleep", "infinity"]
```

**Entrypoint update: `computer/parachute/docker/entrypoint.py`**

Update to accept enriched stdin JSON payload (for persistent mode where capabilities and system_prompt can't be mounted as files):

```python
# Current: reads {"message": "..."} from stdin
# New: reads {"message": "...", "claude_token": "...", "capabilities": {...}, "system_prompt": "..."} from stdin
# Falls back to env vars and mounted files if fields are missing (backward compat with ephemeral mode)

data = json.loads(sys.stdin.readline())
message = data["message"]

# Token: prefer stdin payload, fall back to env var
oauth_token = data.get("claude_token") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")

# Capabilities: prefer stdin payload, fall back to mounted file
capabilities = data.get("capabilities")
if capabilities is None and os.path.exists("/tmp/capabilities.json"):
    with open("/tmp/capabilities.json") as f:
        capabilities = json.load(f)

# System prompt: prefer stdin payload, fall back to mounted file
system_prompt = data.get("system_prompt")
if system_prompt is None and os.path.exists("/tmp/system_prompt.txt"):
    with open("/tmp/system_prompt.txt") as f:
        system_prompt = f.read()
```

**Backward compatibility:** The ephemeral `run_agent()` path continues to work unchanged — it mounts capabilities.json and system_prompt.txt as before, and passes the token via `--env-file`. The entrypoint checks both stdin fields and filesystem/env fallbacks.

### Research Insight: Security Hardening for Persistent Containers

The security reviewer flagged that persistent containers have a larger attack surface than ephemeral ones because state accumulates:

**Mitigations applied in container creation:**
- `--cap-drop ALL` — Remove all Linux capabilities
- `--security-opt no-new-privileges` — Prevent privilege escalation via setuid binaries
- `--pids-limit 100` — Prevent fork bombs from exec sessions
- `--init` — tini ensures clean process management

**Accepted risks:**
- Cross-session filesystem interference is by design (workspace = shared context)
- PATH hijacking within the container is possible but the entrypoint uses absolute paths (`python /workspace/entrypoint.py`)

### Phase 3: Orchestrator Integration

**Modified file: `computer/parachute/core/orchestrator.py`**

The untrusted session path (lines 695-822) currently calls `self._sandbox.run_agent()`. Add persistent container routing:

```python
if effective_trust == "untrusted":
    if workspace_id and await self._sandbox.is_available():
        # Persistent container path — reuses workspace container
        async for event in self._sandbox.run_persistent(
            workspace_slug=workspace_id,
            config=sandbox_config,
            message=sandbox_message,
        ):
            # Same event processing as current sandbox path
            ...
    elif await self._sandbox.is_available():
        # Fallback: ephemeral container (no workspace)
        async for event in self._sandbox.run_agent(sandbox_config, sandbox_message):
            ...
```

**Key change:** No new class injection needed. `self._sandbox` already exists on the Orchestrator. The persistent path is just a new method on the same object.

**Ephemeral `_build_run_args` update:** Since the Dockerfile no longer has `ENTRYPOINT`, the ephemeral path must explicitly pass the entrypoint command:

```python
# In _build_run_args, after the image name:
args.append(SANDBOX_IMAGE)
args.extend(["python", "/workspace/entrypoint.py"])  # NEW — explicit entrypoint
```

### Phase 4: Container Lifecycle in Workspace CRUD

**Modified file: `computer/parachute/api/workspaces.py`**

Wire container cleanup into the DELETE endpoint (keep `core/workspaces.py` clean — it's pure file-based):

```python
@router.delete("/workspaces/{slug}")
async def delete_workspace(slug: str, request: Request):
    orchestrator = request.app.state.orchestrator

    # Stop persistent container before deleting workspace files
    try:
        await orchestrator._sandbox.stop_container(slug)
    except Exception:
        logger.warning(f"Failed to stop container for workspace {slug}")

    # Existing deletion logic (unlink sessions, delete directory)
    ...
```

**Server startup — reconcile:**

```python
# In server.py lifespan, after orchestrator creation:
await orchestrator._sandbox.reconcile()
```

## Files to Modify

| File | Change |
|------|--------|
| `computer/parachute/core/sandbox.py` | Add persistent container methods to DockerSandbox |
| `computer/parachute/core/orchestrator.py` | Route untrusted+workspace sessions through `run_persistent` |
| `computer/parachute/docker/Dockerfile.sandbox` | Remove `ENTRYPOINT`, use `CMD ["sleep", "infinity"]` |
| `computer/parachute/docker/entrypoint.py` | Accept enriched stdin JSON (token, capabilities, system_prompt) |
| `computer/parachute/api/workspaces.py` | Stop container on workspace DELETE |
| `computer/parachute/server.py` | Call `sandbox.reconcile()` on startup |

## Files NOT Modified (deferred)

| File | Why Deferred |
|------|-------------|
| `computer/parachute/cli.py` | CLI container commands are YAGNI — manage via API or docker directly |
| `computer/parachute/api/health.py` | Container health info not needed for MVP |
| `computer/parachute/models/workspace.py` | SandboxConfig already exists; wiring it to actual limits is a separate enhancement |
| `computer/parachute/core/workspaces.py` | Keep pure file-based; container cleanup lives in API layer |

## Key Design Decisions

### 1. `docker exec` per session (not a message daemon)

Each session runs `docker exec -i` to spawn a fresh entrypoint process. The container's PID 1 is `tini` (via `--init`), supervising `sleep infinity`. This:
- Preserves the existing entrypoint unchanged
- Naturally isolates concurrent sessions (separate processes, separate stdin/stdout pipes)
- Passes fresh env vars per-exec (token rotation solved)
- Avoids building a socket-based message router inside the container
- Reaps zombie processes automatically (tini handles orphan cleanup)

### 2. Lazy creation (first untrusted session)

Containers are created on first use, not on workspace creation or server startup. This avoids wasting resources on workspaces that never use untrusted sessions.

### 3. Containers persist across server restarts

Docker containers run independently of the Python server. On startup, `DockerSandbox.reconcile()` discovers existing `parachute-ws-*` containers via Docker labels.

### 4. Token freshness via stdin JSON

Instead of baking the OAuth token into the container at creation time or exposing it via `docker exec -e` (visible in process table), pass it via the stdin JSON payload. The entrypoint reads it from the `claude_token` field, falling back to the `CLAUDE_CODE_OAUTH_TOKEN` env var for backward compatibility with ephemeral mode.

### 5. Ephemeral fallback for workspace-less sessions

Sessions without a `workspace_id` (e.g., ad-hoc sandbox sessions) continue using the current ephemeral `docker run --rm` path. No behavior change for those cases. The ephemeral path now explicitly passes `python /workspace/entrypoint.py` since the Dockerfile ENTRYPOINT was removed.

### 6. No transcript volume mounting (yet)

Continue writing synthetic transcripts on the host side. Don't mount `~/.claude/projects/` into the container. This preserves isolation and keeps the host as source of truth. Can revisit in a future iteration (#26).

### 7. Extend DockerSandbox (not a new class)

Persistent container logic shares 80% of DockerSandbox's infrastructure (mount building, Docker availability, JSONL streaming, timeout handling). Adding methods to the existing class avoids duplication and keeps the Orchestrator unchanged — it already has `self._sandbox`.

### 8. Docker inspect as source of truth

Don't maintain an in-memory `_containers` dict that can drift. Use `docker inspect` to check container status on each `ensure_container` call. The per-slug asyncio.Lock prevents race conditions. Docker labels (`app=parachute`, `workspace={slug}`) enable efficient filtering for `reconcile()`.

## Acceptance Criteria

### Functional Requirements

- [x] First untrusted session in a workspace creates a persistent container
- [x] Subsequent sessions in the same workspace reuse the running container
- [x] Container stays alive between sessions (no `--rm`)
- [x] State persists inside the container (installed packages, file changes)
- [x] Multiple concurrent sessions work in the same container (isolated processes)
- [x] Workspace deletion stops and removes the workspace container
- [x] Server restart discovers existing containers via `reconcile()`
- [x] OAuth token is passed fresh per-exec via stdin JSON (no stale tokens)
- [x] Sessions without a workspace still use ephemeral containers
- [x] Ephemeral mode still works after Dockerfile ENTRYPOINT removal

### Non-Functional Requirements

- [x] First-session container creation completes in <5 seconds (image already pulled)
- [x] Subsequent session exec overhead <1 second vs current ephemeral startup
- [x] No orphan containers after workspace deletion
- [x] No zombie process accumulation (verified via `--init`)
- [x] Graceful degradation when Docker is unavailable (same error as today)
- [x] OOM-killed containers are automatically recreated on next use

## Dependencies & Risks

### Dependencies
- Docker must be installed and running (same as today)
- `parachute-sandbox:latest` image must be built (same as today)
- Workspace system must be functional (already is)

### Risks
- **Shared filesystem between sessions**: Two concurrent sessions can interfere with each other's files. Accepted tradeoff — workspace = shared context by design.
- **Container resource limits are per-workspace, not per-session**: Two concurrent sessions share the memory limit. Could OOM-kill each other under heavy load.
- **Container accumulates state**: No automatic cleanup of installed packages or temp files. Users must restart workspace containers for a clean slate.
- **Image updates require container restart**: Rebuilding the sandbox image doesn't affect running containers. Users must recreate workspace containers to pick up new images.
- **Cross-session privilege escalation**: Persistent filesystem allows one session to influence subsequent sessions. Mitigated by `--cap-drop ALL`, `--security-opt no-new-privileges`, and absolute entrypoint paths.

### Future Enhancements (Deferred)
- Wire `WorkspaceConfig.sandbox.memory/cpu` into actual container limits (currently hardcoded)
- CLI commands for container management (`parachute workspace container-stop`)
- REST API endpoints for container status/control
- Container health info in `/health?detailed=true`
- Memory pressure check before launching new exec sessions
- Pre-compile Python bytecode in Dockerfile for faster exec startup
- Agent-native container state context (inject container info into system prompt)

## Related Issues

- #26: Sandbox Session Persistence — Complementary (persisting SDK data via bind mounts). Can be layered on top of persistent containers later.
- #23: Bot Management Overhaul — Bot sessions with workspace_ids would use persistent containers.
- #29: Desktop/Telegram Integration — Bot connector sessions benefit from persistent containers.

## References

- Current sandbox implementation: `computer/parachute/core/sandbox.py`
- Orchestrator untrusted path: `computer/parachute/core/orchestrator.py:695-822`
- Workspace model with SandboxConfig: `computer/parachute/models/workspace.py:33-38, 79-118`
- Docker entrypoint: `computer/parachute/docker/entrypoint.py`
- Dockerfile: `computer/parachute/docker/Dockerfile.sandbox`
- Server lifespan: `computer/parachute/server.py:45-150`
- Workspace CRUD: `computer/parachute/core/workspaces.py`, `computer/parachute/api/workspaces.py`
- Docker exec isolation: https://labs.iximiuz.com/tutorials/docker-run-vs-attach-vs-exec
- tini/init process: https://github.com/krallin/tini
- Docker resource constraints: https://docs.docker.com/engine/containers/resource_constraints/
