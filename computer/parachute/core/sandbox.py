"""
Docker sandbox for agent execution.

Provides per-agent Docker containers with scoped filesystem mounts
and credential propagation for the Claude Agent SDK.

Used for all untrusted sessions. Docker must be available — no fallback.
"""

import asyncio
import json
import logging
import os
import re
import shutil
import tempfile
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncGenerator, Optional

from parachute.core.validation import SANDBOX_DATA_DIR, validate_workspace_slug

logger = logging.getLogger(__name__)

# Default sandbox image (pre-built with Claude SDK + Python)
SANDBOX_IMAGE = "parachute-sandbox:latest"

# Container resource limits
CONTAINER_MEMORY_LIMIT = "512m"
CONTAINER_CPU_LIMIT = "1.0"


@dataclass
class AgentSandboxConfig:
    """Configuration for a sandboxed agent execution."""

    session_id: str
    agent_type: str = "chat"
    allowed_paths: list[str] = field(default_factory=list)
    network_enabled: bool = False
    timeout_seconds: int = 300  # 5 minute default
    plugin_dirs: list[Path] = field(default_factory=list)
    mcp_servers: Optional[dict] = None  # Filtered MCP configs to pass to container
    agents: Optional[dict] = None
    working_directory: Optional[str] = None  # /vault/... absolute path for container CWD
    model: Optional[str] = None  # Model to use (e.g., "claude-opus-4-6")
    system_prompt: Optional[str] = None  # System prompt to pass to SDK inside container


class DockerSandbox:
    """Manages Docker containers for sandboxed agent execution."""

    # Re-check Docker availability every 60 seconds
    _CACHE_TTL = 60

    def __init__(self, vault_path: Path, claude_token: Optional[str] = None):
        self.vault_path = vault_path
        self.claude_token = claude_token
        self._docker_available: Optional[bool] = None
        self._checked_at: float = 0
        # Per-workspace locks to prevent race conditions in ensure_container
        self._slug_locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

    async def is_available(self) -> bool:
        """Check if Docker is installed and running (cached with TTL)."""
        if (self._docker_available is not None
                and (time.time() - self._checked_at) < self._CACHE_TTL):
            return self._docker_available

        if not shutil.which("docker"):
            logger.warning("Docker not found in PATH")
            self._docker_available = False
            self._checked_at = time.time()
            return False

        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "info",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=5.0)
            self._docker_available = proc.returncode == 0
            self._checked_at = time.time()
            if not self._docker_available:
                logger.warning("Docker daemon not running")
            return self._docker_available
        except (asyncio.TimeoutError, OSError):
            logger.warning("Docker check timed out or failed")
            self._docker_available = False
            self._checked_at = time.time()
            return False

    async def image_exists(self) -> bool:
        """Check if the sandbox image is available."""
        if not await self.is_available():
            return False
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "image", "inspect", SANDBOX_IMAGE,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=10.0)
            return proc.returncode == 0
        except (asyncio.TimeoutError, OSError):
            return False

    def _build_mounts(self, config: AgentSandboxConfig) -> list[str]:
        """Build Docker volume mount flags based on config."""
        mounts = []

        # Mount allowed vault paths
        for path_pattern in config.allowed_paths:
            # Strip glob suffixes to get directory path
            clean = re.sub(r'(/\*\*?)*$', '', path_pattern)
            if not clean:
                continue
            # Paths may be /vault/... absolute or legacy relative
            if clean.startswith("/vault/"):
                # Already absolute /vault/ path — resolve to host path
                relative = clean[len("/vault/"):]
                full_path = self.vault_path / relative
                container_path = clean
            else:
                # Legacy relative path
                full_path = self.vault_path / clean
                container_path = f"/vault/{clean}"
            if full_path.exists():
                mounts.extend(["-v", f"{full_path}:{container_path}:rw"])
                logger.debug(f"Mounting {full_path} -> {container_path}:rw")
            else:
                logger.warning(f"Skipping non-existent path: {full_path}")

        # If no specific paths, mount entire vault read-only
        if not config.allowed_paths:
            mounts.extend(["-v", f"{self.vault_path}:/vault:ro"])
            logger.debug(f"Mounting entire vault read-only: {self.vault_path} -> /vault:ro")

        # Mount capability files/dirs
        mounts.extend(self._build_capability_mounts(config))

        logger.info(f"Docker mounts: {len(mounts) // 2} volumes, wd={config.working_directory}")
        return mounts

    def _build_capability_mounts(self, config: AgentSandboxConfig) -> list[str]:
        """Build Docker volume mounts for capabilities (MCP, skills, agents, plugins)."""
        mounts = []

        # Mount vault MCP config (read-only)
        mcp_json = self.vault_path / ".mcp.json"
        if mcp_json.exists():
            mounts.extend(["-v", f"{mcp_json}:/vault/.mcp.json:ro"])

        # Mount skills directory (read-only)
        skills_dir = self.vault_path / ".skills"
        if skills_dir.is_dir():
            mounts.extend(["-v", f"{skills_dir}:/vault/.skills:ro"])

        # Mount custom agents (read-only)
        agents_dir = self.vault_path / ".parachute" / "agents"
        if agents_dir.is_dir():
            mounts.extend(["-v", f"{agents_dir}:/vault/.parachute/agents:ro"])

        # Mount vault CLAUDE.md (read-only)
        claude_md = self.vault_path / "CLAUDE.md"
        if claude_md.exists():
            mounts.extend(["-v", f"{claude_md}:/vault/CLAUDE.md:ro"])

        # Mount plugin directories (read-only)
        for i, plugin_dir in enumerate(config.plugin_dirs):
            if plugin_dir.is_dir():
                mounts.extend(["-v", f"{plugin_dir}:/plugins/plugin-{i}:ro"])

        return mounts

    def _build_run_args(self, config: AgentSandboxConfig) -> tuple[list[str], list[str]]:
        """Build complete docker run arguments.

        Returns (args, temp_files) where temp_files must be cleaned up
        after the container exits.
        """
        # Validate session_id is safe for Docker --name
        if not re.match(r'^[a-zA-Z0-9_-]+$', config.session_id):
            raise ValueError(f"Invalid session_id format: {config.session_id[:20]}")

        args = [
            "docker", "run",
            "--rm",
            "-i",  # Interactive mode: accept stdin for message passing
            "--init",  # tini as PID 1 — reaps zombies, forwards signals
            "--name", f"parachute-sandbox-{config.session_id[:8]}",
            "--memory", CONTAINER_MEMORY_LIMIT,
            "--cpus", CONTAINER_CPU_LIMIT,
            # Security hardening (match persistent container flags)
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--pids-limit", "100",
        ]

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])

        # Volume mounts
        args.extend(self._build_mounts(config))

        # Track temp files for cleanup
        temp_files: list[str] = []

        # Environment variables via --env-file to avoid token exposure in process table
        env_lines = [
            f"PARACHUTE_SESSION_ID={config.session_id}",
            f"PARACHUTE_AGENT_TYPE={config.agent_type}",
        ]
        if self.claude_token:
            env_lines.append(f"CLAUDE_CODE_OAUTH_TOKEN={self.claude_token}")
        else:
            logger.warning("No claude_token configured for sandbox — container will fail auth")

        # Set container working directory (path already starts with /vault/)
        if config.working_directory:
            env_lines.append(f"PARACHUTE_CWD={config.working_directory}")

        # Pass model configuration to sandbox
        if config.model:
            env_lines.append(f"PARACHUTE_MODEL={config.model}")

        # Pass filtered MCP server names so the container knows what's allowed
        if config.mcp_servers is not None:
            mcp_names = ",".join(config.mcp_servers.keys())
            env_lines.append(f"PARACHUTE_MCP_SERVERS={mcp_names}")

        fd, env_file_path = tempfile.mkstemp(suffix='.env', prefix='parachute-sandbox-')
        try:
            with os.fdopen(fd, 'w') as f:
                f.write('\n'.join(env_lines) + '\n')
            os.chmod(env_file_path, 0o600)
            args.extend(["--env-file", env_file_path])
            temp_files.append(env_file_path)
        except Exception:
            os.unlink(env_file_path)
            raise

        # Write capabilities JSON for the entrypoint to read
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
            fd2, caps_file_path = tempfile.mkstemp(
                suffix='.json', prefix='parachute-caps-'
            )
            try:
                with os.fdopen(fd2, 'w') as f:
                    json.dump(capabilities, f)
                os.chmod(caps_file_path, 0o600)
                args.extend(["-v", f"{caps_file_path}:/tmp/capabilities.json:ro"])
                temp_files.append(caps_file_path)
            except Exception:
                os.unlink(caps_file_path)
                logger.warning("Failed to write capabilities config for sandbox")

        # Mount system prompt as file (avoids env var size limits)
        if config.system_prompt:
            fd3, prompt_file = tempfile.mkstemp(
                suffix='.txt', prefix='parachute-prompt-'
            )
            try:
                with os.fdopen(fd3, 'w') as f:
                    f.write(config.system_prompt)
                os.chmod(prompt_file, 0o600)
                args.extend(["-v", f"{prompt_file}:/tmp/system_prompt.txt:ro"])
                temp_files.append(prompt_file)
            except Exception:
                os.unlink(prompt_file)
                logger.warning("Failed to write system prompt for sandbox")

        # Image + explicit entrypoint (Dockerfile uses CMD sleep infinity for persistent mode)
        args.extend([SANDBOX_IMAGE, "python", "/workspace/entrypoint.py"])

        return args, temp_files

    async def _stream_process(
        self,
        proc: asyncio.subprocess.Process,
        stdin_payload: dict,
        config: AgentSandboxConfig,
        label: str = "sandbox",
    ) -> AsyncGenerator[dict, None]:
        """Stream JSONL events from a subprocess, handling timeouts and errors.

        Shared by run_agent (ephemeral) and run_persistent (persistent).
        Caller is responsible for creating the subprocess and any post-cleanup.
        """
        if proc.stdin is None or proc.stdout is None:
            yield {"type": "error", "error": f"Failed to open pipes to {label} container"}
            return

        proc.stdin.write(json.dumps(stdin_payload).encode() + b"\n")
        await proc.stdin.drain()
        proc.stdin.close()

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
                logger.debug(f"Non-JSON from {label}: {line.decode().strip()}")

        if timed_out:
            logger.error(f"{label.capitalize()} timed out for session {config.session_id}")
            proc.kill()
            yield {"type": "error", "error": "Sandbox execution timed out"}
            return

        try:
            await asyncio.wait_for(proc.wait(), timeout=10)
        except asyncio.TimeoutError:
            proc.kill()

        if proc.returncode and proc.returncode != 0:
            stderr_data = b""
            if proc.stderr:
                stderr_data = await proc.stderr.read()
            logger.error(f"{label.capitalize()} exited {proc.returncode}: {stderr_data.decode()}")
            yield {"type": "exit_error", "returncode": proc.returncode}

    async def run_agent(
        self,
        config: AgentSandboxConfig,
        message: str,
    ) -> AsyncGenerator[dict, None]:
        """Run an agent in a Docker container, yielding streaming events.

        Events are JSON objects written to stdout, one per line (JSONL).
        """
        if not await self.is_available():
            raise RuntimeError("Docker not available for sandboxed execution")

        if not await self.image_exists():
            raise RuntimeError(
                f"Sandbox image '{SANDBOX_IMAGE}' not found. "
                "Build it from Settings > Capabilities or run: "
                "docker build -t parachute-sandbox:latest parachute-computer/parachute/docker/"
            )

        args, temp_files = self._build_run_args(config)

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            async for event in self._stream_process(
                proc, {"message": message}, config, label="sandbox"
            ):
                if event.get("type") == "exit_error":
                    yield {"type": "error", "error": f"Sandbox error (exit {event['returncode']})"}
                else:
                    yield event

        except OSError as e:
            logger.error(f"Failed to start sandbox: {e}")
            yield {"type": "error", "error": f"Failed to start sandbox: {e}"}
        finally:
            for tmp_file in temp_files:
                try:
                    os.unlink(tmp_file)
                except OSError:
                    pass

    def health_info(self) -> dict:
        """Return Docker health info for /health endpoint."""
        return {
            "docker_available": self._docker_available,
            "sandbox_image": SANDBOX_IMAGE,
        }

    # --- Persistent container methods ---

    @staticmethod
    def _validate_slug(slug: str) -> None:
        """Validate workspace slug is safe for Docker container names."""
        validate_workspace_slug(slug)

    def get_sandbox_claude_dir(self, workspace_slug: str) -> Path:
        """Host-side .claude/ directory for a workspace's sandbox."""
        validate_workspace_slug(workspace_slug)
        return self.vault_path / SANDBOX_DATA_DIR / workspace_slug / ".claude"

    def has_sdk_transcript(self, workspace_slug: str, session_id: str) -> bool:
        """Check if an SDK transcript exists on the host mount for a workspace session.

        Skips symlinks to defend against container-created symlink escapes.
        Safe for use in asyncio.to_thread() — all I/O is synchronous.
        """
        claude_dir = self.get_sandbox_claude_dir(workspace_slug)
        projects_dir = claude_dir / "projects"
        if not projects_dir.exists():
            return False
        filename = f"{session_id}.jsonl"
        for project_dir in projects_dir.iterdir():
            if project_dir.is_symlink():
                continue
            candidate = project_dir / filename
            if candidate.exists() and not candidate.is_symlink():
                return True
        return False

    def cleanup_workspace_data(self, workspace_slug: str) -> None:
        """Remove persistent sandbox data for a workspace."""
        validate_workspace_slug(workspace_slug)
        sandbox_dir = self.vault_path / SANDBOX_DATA_DIR / workspace_slug
        if sandbox_dir.is_symlink():
            logger.warning(f"Sandbox dir is a symlink, removing link only: {sandbox_dir}")
            sandbox_dir.unlink()
        elif sandbox_dir.exists():
            shutil.rmtree(sandbox_dir)

    async def ensure_container(
        self, workspace_slug: str, config: AgentSandboxConfig
    ) -> str:
        """Ensure a persistent container is running for this workspace.

        Returns the container name. Creates the container lazily on first call.
        Uses per-slug asyncio.Lock to prevent race conditions.
        """
        self._validate_slug(workspace_slug)
        container_name = f"parachute-ws-{workspace_slug}"

        async with self._slug_locks[workspace_slug]:
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

        # Network — persistent containers need network for SDK API calls
        if not config.network_enabled:
            args.extend(["--network", "none"])

        # Volume mounts (reuse existing _build_mounts)
        args.extend(self._build_mounts(config))

        # Mount host .claude/ directory for SDK session persistence
        sandbox_claude_dir = self.get_sandbox_claude_dir(workspace_slug)
        sandbox_claude_dir.mkdir(parents=True, exist_ok=True)
        sandbox_claude_dir.chmod(0o700)
        args.extend(["-v", f"{sandbox_claude_dir}:/home/sandbox/.claude:rw"])

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
        logger.info(
            f"Created persistent container {container_name} "
            f"for workspace {workspace_slug}"
        )

    async def run_persistent(
        self,
        workspace_slug: str,
        config: AgentSandboxConfig,
        message: str,
        resume_session_id: str | None = None,
    ) -> AsyncGenerator[dict, None]:
        """Run an agent session in a persistent workspace container.

        Uses docker exec to spawn a process in the running container.
        Per-session data (capabilities, system_prompt, token) is passed
        via enriched stdin JSON payload since docker exec cannot mount volumes.

        If resume_session_id is set, the entrypoint will attempt SDK resume
        from the persisted transcript on the mounted .claude/ directory.
        """
        if not await self.is_available():
            raise RuntimeError("Docker not available for sandboxed execution")

        if not await self.image_exists():
            raise RuntimeError(
                f"Sandbox image '{SANDBOX_IMAGE}' not found. "
                "Build it from Settings > Capabilities or run: "
                "docker build -t parachute-sandbox:latest parachute-computer/parachute/docker/"
            )

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
            # Build enriched stdin payload — includes secrets and per-session data
            # that can't be passed via docker exec volume mounts
            stdin_payload: dict = {"message": message}
            if self.claude_token:
                stdin_payload["claude_token"] = self.claude_token
            if config.system_prompt:
                stdin_payload["system_prompt"] = config.system_prompt
            if resume_session_id:
                stdin_payload["resume_session_id"] = resume_session_id

            # Capabilities
            capabilities: dict = {}
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

            async for event in self._stream_process(
                proc, stdin_payload, config, label="persistent sandbox"
            ):
                if event.get("type") == "exit_error":
                    returncode = event["returncode"]
                    # Exit code 137 = OOM killed — remove so next use recreates
                    if returncode == 137:
                        logger.warning(
                            f"Container {container_name} OOM killed, "
                            f"will recreate on next use"
                        )
                        await self._remove_container(container_name)
                        yield {
                            "type": "error",
                            "error": "Container ran out of memory. "
                                     "It will be recreated on next use.",
                        }
                    else:
                        yield {
                            "type": "error",
                            "error": f"Sandbox error (exit {returncode})",
                        }
                else:
                    yield event

        except OSError as e:
            logger.error(f"Failed to exec in persistent sandbox: {e}")
            yield {"type": "error", "error": f"Failed to exec in sandbox: {e}"}
        finally:
            if proc.returncode is None:
                try:
                    proc.kill()
                    await proc.wait()
                except ProcessLookupError:
                    pass

    async def stop_container(self, workspace_slug: str) -> None:
        """Stop and remove a workspace's persistent container."""
        self._validate_slug(workspace_slug)
        container_name = f"parachute-ws-{workspace_slug}"
        await self._stop_container(container_name)
        await self._remove_container(container_name)
        self._slug_locks.pop(workspace_slug, None)

    async def _start_container(self, container_name: str) -> None:
        """Start a stopped container."""
        proc = await asyncio.create_subprocess_exec(
            "docker", "start", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"Failed to start {container_name}: {stderr.decode()}"
            )

    async def _stop_container(self, container_name: str) -> None:
        """Stop a running container with 10s grace period."""
        proc = await asyncio.create_subprocess_exec(
            "docker", "stop", "-t", "10", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            await asyncio.wait_for(proc.wait(), timeout=15)
        except asyncio.TimeoutError:
            pass

    async def _remove_container(self, container_name: str) -> None:
        """Force-remove a container."""
        proc = await asyncio.create_subprocess_exec(
            "docker", "rm", "-f", container_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

    async def reconcile(self) -> None:
        """Discover existing parachute-ws-* containers on server startup.

        Logs the count of existing workspace containers. Does not remove
        orphans — that's deferred to a future cleanup task.
        """
        if not await self.is_available():
            return

        proc = await asyncio.create_subprocess_exec(
            "docker", "ps", "-a",
            "--filter", "label=app=parachute",
            "--format", "{{.Names}}\t{{.Status}}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode != 0:
            logger.warning("Failed to discover existing workspace containers")
            return

        count = 0
        for line in stdout.decode().strip().split("\n"):
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 1 and parts[0].startswith("parachute-ws-"):
                count += 1
        if count:
            logger.info(
                f"Reconciled {count} existing workspace container(s)"
            )
