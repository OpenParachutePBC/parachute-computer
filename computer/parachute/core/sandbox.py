"""
Docker sandbox for agent execution.

Provides per-session Docker containers with scoped filesystem mounts
and credential propagation for the Claude Agent SDK.

Used for all sandboxed sessions. Docker must be available — no fallback.

Two container modes:
- Session containers (parachute-session-<session_id[:12]>): private, per-session,
  removed when the session is deleted or archived
- Named env containers (parachute-env-<slug>): shared, persist until explicitly deleted,
  multiple sessions can join the same env and share /home/sandbox/
"""

import asyncio
import hashlib
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
from typing import Any, AsyncGenerator

from parachute.lib.credentials import load_credentials
from parachute.models.session import BOT_SOURCES, SessionSource

SANDBOX_DATA_DIR = ".parachute/sandbox"
SANDBOX_NETWORK_NAME = "parachute-sandbox"

logger = logging.getLogger(__name__)

# Default sandbox image (pre-built with Claude SDK + Python)
SANDBOX_IMAGE = "parachute-sandbox:latest"

# Shared read-only tools volume — mounted at /opt/parachute-tools in all containers
TOOLS_VOLUME_NAME = "parachute-tools"

# Container resource limits
# Ephemeral containers (--rm, short-lived) can run with less memory.
# Persistent containers need more — the Claude SDK process alone uses 300–500 MB.
CONTAINER_MEMORY_LIMIT_EPHEMERAL = "512m"
CONTAINER_MEMORY_LIMIT_PERSISTENT = "1.5g"
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
    mcp_servers: dict[str, Any] | None = None  # Filtered MCP configs to pass to container
    agents: dict[str, Any] | None = None
    working_directory: str | None = None  # /vault/... absolute path for container CWD
    model: str | None = None  # Model to use (e.g., "claude-opus-4-6")
    system_prompt: str | None = None  # System prompt to pass to SDK inside container
    session_source: SessionSource | None = None  # Used to gate credential injection


class DockerSandbox:
    """Manages Docker containers for sandboxed agent execution."""

    # Re-check Docker availability every 60 seconds
    _CACHE_TTL = 60

    def __init__(self, vault_path: Path, claude_token: str | None = None):
        self.vault_path = vault_path
        self.claude_token = claude_token
        self._docker_available: bool | None = None
        self._checked_at: float = 0
        # Per-container locks to prevent race conditions during container creation
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

    def _calculate_config_hash(self) -> str:
        """Calculate a stable hash of sandbox configuration.

        Used for container reconciliation — containers with different config hashes
        are rebuilt rather than reused. Ensures all running containers match the
        current sandbox image and resource limits.

        Returns:
            12-character hex hash (48 bits entropy, collision-resistant for ~16M configs)
        """
        # Combine image tag and resource limits into deterministic string.
        # Bump the trailing version string whenever hardening flags change to
        # force reconcile() to rebuild containers on the next server restart.
        config_str = f"{SANDBOX_IMAGE}:{CONTAINER_MEMORY_LIMIT_PERSISTENT}:{CONTAINER_CPU_LIMIT}:v3"

        # SHA-256 hash, truncate to 12 chars (48 bits)
        hash_digest = hashlib.sha256(config_str.encode()).hexdigest()
        return hash_digest[:12]

    def _build_mounts(self, config: AgentSandboxConfig) -> list[str]:
        """Build Docker volume mount flags based on config."""
        mounts = []

        # Mount allowed vault paths
        for path_pattern in config.allowed_paths:
            # Strip glob suffixes to get directory path
            clean = re.sub(r'(/\*\*?)*$', '', path_pattern)
            if not clean:
                continue
            # Paths may be ~/Parachute/... or legacy /vault/ or relative
            if clean.startswith("~/Parachute/"):
                # New format - convert to absolute path
                relative = clean[len("~/Parachute/"):]
                full_path = self.vault_path / relative
                container_path = f"/home/sandbox/Parachute/{relative}"
            elif clean.startswith("/vault/"):
                # Legacy absolute /vault/ path — migrate to /home/sandbox/Parachute/
                relative = clean[len("/vault/"):]
                full_path = self.vault_path / relative
                container_path = f"/home/sandbox/Parachute/{relative}"
            else:
                # Legacy relative path
                full_path = self.vault_path / clean
                container_path = f"/home/sandbox/Parachute/{clean}"
            if full_path.exists():
                mounts.extend(["-v", f"{full_path}:{container_path}:rw"])
                logger.debug(f"Mounting {full_path} -> {container_path}:rw")
            else:
                logger.warning(f"Skipping non-existent path: {full_path}")

        # If no specific paths, mount entire vault read-only
        if not config.allowed_paths:
            mounts.extend(["-v", f"{self.vault_path}:/home/sandbox/Parachute:ro"])
            logger.debug(f"Mounting entire vault read-only: {self.vault_path} -> /home/sandbox/Parachute:ro")

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
            mounts.extend(["-v", f"{mcp_json}:/home/sandbox/Parachute/.mcp.json:ro"])

        # Mount skills directory (read-only)
        skills_dir = self.vault_path / ".skills"
        if skills_dir.is_dir():
            mounts.extend(["-v", f"{skills_dir}:/home/sandbox/Parachute/.skills:ro"])

        # Mount custom agents (read-only)
        agents_dir = self.vault_path / ".parachute" / "agents"
        if agents_dir.is_dir():
            mounts.extend(["-v", f"{agents_dir}:/home/sandbox/Parachute/.parachute/agents:ro"])

        # Mount vault CLAUDE.md (read-only)
        claude_md = self.vault_path / "CLAUDE.md"
        if claude_md.exists():
            mounts.extend(["-v", f"{claude_md}:/home/sandbox/Parachute/CLAUDE.md:ro"])

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
            "--memory", CONTAINER_MEMORY_LIMIT_EPHEMERAL,
            "--memory-swap", CONTAINER_MEMORY_LIMIT_EPHEMERAL,  # no swap
            "--cpus", CONTAINER_CPU_LIMIT,
            # Security hardening (match persistent container flags)
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--pids-limit", "100",
            "--ulimit", "nproc=64:64",
            "--ulimit", "nofile=4096:8192",
            # Per-session scratch space (tmpfs — no disk persistence)
            "--tmpfs", "/scratch:size=512m,uid=1000,gid=1000",
            "--tmpfs", "/tmp:size=128m,uid=1000,gid=1000",
            "--tmpfs", "/run:size=32m,uid=1000,gid=1000",
        ]

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])
        else:
            args.extend([
                "--network", SANDBOX_NETWORK_NAME,
                "--add-host", "host.docker.internal:host-gateway",
            ])

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

    async def _validate_docker_ready(self) -> None:
        """Validate Docker and sandbox image are available.

        Raises RuntimeError if Docker is not available or image is missing.
        """
        if not await self.is_available():
            raise RuntimeError("Docker not available for sandboxed execution")

        if not await self.image_exists():
            raise RuntimeError(
                f"Sandbox image '{SANDBOX_IMAGE}' not found. "
                "Build it from Settings > Capabilities or run: "
                "docker build -t parachute-sandbox:latest parachute-computer/parachute/docker/"
            )

    async def run_agent(
        self,
        config: AgentSandboxConfig,
        message: str,
    ) -> AsyncGenerator[dict, None]:
        """Run an agent in a Docker container, yielding streaming events.

        Events are JSON objects written to stdout, one per line (JSONL).
        """
        await self._validate_docker_ready()

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

    def _get_session_claude_dir(self, session_id: str) -> Path:
        """Host-side .claude/ directory for a private session container."""
        return self.vault_path / SANDBOX_DATA_DIR / "sessions" / session_id[:8] / ".claude"

    def _get_named_env_claude_dir(self, slug: str) -> Path:
        """Host-side .claude/ directory for a named env container."""
        return self.vault_path / SANDBOX_DATA_DIR / "envs" / slug / ".claude"

    async def _ensure_container(
        self,
        container_name: str,
        claude_dir: Path,
        labels: dict[str, str],
        config: AgentSandboxConfig,
    ) -> str:
        """Ensure a persistent container is running; create if absent, start if stopped.

        Shared implementation for session and named-env containers.
        """
        async with self._slug_locks[container_name]:
            status = await self._inspect_status(container_name)

            if status == "running":
                return container_name
            elif status in ("exited", "created"):
                await self._start_container(container_name)
                return container_name
            elif status is not None:
                await self._remove_container(container_name)

            if config.network_enabled:
                await self._ensure_sandbox_network()

            vault_mounts = ["-v", f"{self.vault_path}:/home/sandbox/Parachute:ro"]
            vault_mounts.extend(self._build_capability_mounts(config))

            args = self._build_persistent_container_args(
                container_name, config, labels, claude_dir, vault_mounts
            )

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
            logger.info(f"Created container {container_name}")
            return container_name

    async def ensure_session_container(
        self, session_id: str, config: AgentSandboxConfig
    ) -> str:
        """Ensure a private session container is running.

        Container: parachute-session-<session_id[:12]>
        Creates lazily on first call; idempotent on subsequent calls.
        """
        container_name = f"parachute-session-{session_id[:12]}"
        claude_dir = self._get_session_claude_dir(session_id)
        labels = {
            "app": "parachute",
            "type": "session",
            "session_id": session_id,
            "config_hash": self._calculate_config_hash(),
        }
        return await self._ensure_container(container_name, claude_dir, labels, config)

    async def ensure_named_container(
        self, slug: str, config: AgentSandboxConfig
    ) -> str:
        """Ensure a named env container is running.

        Container: parachute-env-<slug>
        Creates if absent, starts if stopped. Multiple sessions share one container.
        """
        container_name = f"parachute-env-{slug}"
        claude_dir = self._get_named_env_claude_dir(slug)
        labels = {
            "app": "parachute",
            "type": "named-env",
            "env_slug": slug,
            "config_hash": self._calculate_config_hash(),
        }
        return await self._ensure_container(container_name, claude_dir, labels, config)

    async def run_session(
        self,
        session_id: str,
        config: AgentSandboxConfig,
        message: str,
        resume_session_id: str | None = None,
        container_env_slug: str | None = None,
    ) -> AsyncGenerator[dict, None]:
        """Run an agent session in a container, yielding streaming events.

        If container_env_slug is provided, exec into the named env container.
        Otherwise, ensure a private session container and exec into it.
        """
        await self._validate_docker_ready()

        if container_env_slug is not None:
            target = await self.ensure_named_container(container_env_slug, config)
        else:
            target = await self.ensure_session_container(session_id, config)

        async for event in self._run_in_container(
            target, config, message, resume_session_id, "sandbox"
        ):
            yield event

    async def stop_session_container(self, session_id: str) -> None:
        """Stop and remove a private session container."""
        container_name = f"parachute-session-{session_id[:12]}"
        await self._stop_container(container_name)
        await self._remove_container(container_name)
        self._slug_locks.pop(container_name, None)

    async def delete_named_container(self, slug: str) -> None:
        """Stop and remove a named env container."""
        container_name = f"parachute-env-{slug}"
        await self._stop_container(container_name)
        await self._remove_container(container_name)
        self._slug_locks.pop(container_name, None)

    async def _inspect_status(self, container_name: str) -> str | None:
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

    def _build_persistent_container_args(
        self,
        container_name: str,
        config: AgentSandboxConfig,
        labels: dict[str, str],
        claude_dir: Path,
        vault_mounts: list[str],
    ) -> list[str]:
        """Build docker run arguments for a persistent container.

        Args:
            container_name: Name for the container
            config: Sandbox configuration
            labels: Docker labels for discovery
            claude_dir: Host .claude/ directory to mount for SDK persistence
            vault_mounts: Vault volume mount arguments (from _build_mounts or custom)

        Returns:
            Complete docker run command arguments
        """
        args = [
            "docker", "run", "-d",
            "--init",  # tini as PID 1 — reaps zombies, forwards signals
            "--name", container_name,
            "--memory", CONTAINER_MEMORY_LIMIT_PERSISTENT,
            "--memory-swap", CONTAINER_MEMORY_LIMIT_PERSISTENT,  # no swap
            "--cpus", CONTAINER_CPU_LIMIT,
            # Security hardening
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--pids-limit", "100",
            "--ulimit", "nproc=64:64",
            "--ulimit", "nofile=4096:8192",
            # /tmp and /run as tmpfs (no disk persistence)
            "--tmpfs", "/tmp:size=128m,uid=1000,gid=1000",
            "--tmpfs", "/run:size=32m,uid=1000,gid=1000",
        ]

        # Add labels
        for key, value in labels.items():
            args.extend(["--label", f"{key}={value}"])

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])
        else:
            args.extend([
                "--network", SANDBOX_NETWORK_NAME,
                "--add-host", "host.docker.internal:host-gateway",
            ])

        # Vault mounts
        args.extend(vault_mounts)

        # Shared tools volume (read-only) — bin/ in PATH, python/ in PYTHONPATH
        args.extend([
            "--mount",
            f"source={TOOLS_VOLUME_NAME},target=/opt/parachute-tools,readonly",
        ])

        # SDK session persistence
        claude_dir.mkdir(parents=True, exist_ok=True)
        claude_dir.chmod(0o700)
        args.extend(["-v", f"{claude_dir}:/home/sandbox/.claude:rw"])

        # Image + keep-alive command
        args.extend([SANDBOX_IMAGE, "sleep", "infinity"])

        return args

    async def _run_in_container(
        self,
        container_name: str,
        config: AgentSandboxConfig,
        message: str,
        resume_session_id: str | None,
        label: str,
    ) -> AsyncGenerator[dict, None]:
        """Execute an agent session in a running container via docker exec.

        Shared by run_persistent and run_default. Handles exec args, stdin payload
        construction, streaming, and OOM cleanup.

        Args:
            container_name: Running container to exec into
            config: Sandbox configuration
            message: User message to send
            resume_session_id: Optional SDK session ID to resume
            label: Label for logging (e.g., "persistent sandbox", "default sandbox")
        """
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

            # Inject credentials for known non-bot sources only.
            # Require explicit non-bot confirmation: None (unknown caller) gets no credentials.
            # Bot sessions (Telegram/Discord/Matrix) and unknown sources never receive host credentials.
            if config.session_source is not None and config.session_source not in BOT_SOURCES:
                creds = load_credentials(self.vault_path)
                if creds:
                    logger.debug(
                        f"Injecting credentials into container: "
                        f"keys={list(creds.keys())} (values redacted)"
                    )
                stdin_payload["credentials"] = creds
            else:
                stdin_payload["credentials"] = {}

            async for event in self._stream_process(
                proc, stdin_payload, config, label=label
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
            logger.error(f"Failed to exec in {label}: {e}")
            yield {"type": "error", "error": f"Failed to exec in sandbox: {e}"}
        finally:
            if proc.returncode is None:
                try:
                    proc.kill()
                    await proc.wait()
                except ProcessLookupError:
                    pass

    async def _ensure_sandbox_network(self) -> None:
        """Create the parachute-sandbox bridge network if it doesn't exist.

        Idempotent — safe to call before every container creation.
        The named user-defined bridge provides network-level isolation:
        sandbox containers cannot reach containers on other networks.
        """
        proc = await asyncio.create_subprocess_exec(
            "docker", "network", "create",
            "--driver", "bridge",
            SANDBOX_NETWORK_NAME,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        # returncode 0 = created, 1 = already exists — both are fine

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

    async def _ensure_tools_volume(self) -> None:
        """Create the parachute-tools named volume if it doesn't exist.

        The tools volume is mounted read-only at /opt/parachute-tools in all
        containers. Anything written to it is immediately visible to all running
        containers (for tool installs, pip packages, etc.).
        """
        proc = await asyncio.create_subprocess_exec(
            "docker", "volume", "create", TOOLS_VOLUME_NAME,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        # returncode 0 = created, may also succeed if already exists

    async def reconcile(self, active_session_ids: set[str] | None = None) -> None:
        """Reconcile parachute containers on server startup.

        Actions:
        - Create parachute-tools volume if absent
        - Remove all legacy parachute-ws-* and parachute-default containers immediately
        - Remove orphaned parachute-session-* containers (no matching active session)
        - Log discovered parachute-env-* (named env) containers

        Args:
            active_session_ids: Set of session IDs currently in the DB (short prefix
                not needed — full IDs compared against container name prefix).
                If None, skip orphan cleanup for session containers.
        """
        if not await self.is_available():
            return

        # Ensure shared tools volume exists
        await self._ensure_tools_volume()

        proc = await asyncio.create_subprocess_exec(
            "docker", "ps", "-a",
            "--filter", "label=app=parachute",
            "--format", "{{json .}}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode != 0:
            logger.warning("Failed to list parachute containers for reconcile")
            return

        containers_to_remove: list[str] = []
        named_env_names: list[str] = []

        for line in stdout.decode().strip().split("\n"):
            if not line:
                continue

            try:
                container = json.loads(line)
                name = container.get("Names", "")

                # Immediately remove legacy containers
                if name.startswith("parachute-ws-") or name == "parachute-default":
                    logger.info(f"Removing legacy container: {name}")
                    containers_to_remove.append(name)
                    continue

                # Named env containers — log and leave running
                if name.startswith("parachute-env-"):
                    named_env_names.append(name)
                    continue

                # Session containers — remove if orphaned (no active session)
                if name.startswith("parachute-session-"):
                    if active_session_ids is not None:
                        # Container name prefix is 12 chars of session_id
                        prefix = name[len("parachute-session-"):]
                        # Check if any active session starts with this prefix
                        is_active = any(sid.startswith(prefix) for sid in active_session_ids)
                        if not is_active:
                            logger.info(f"Removing orphaned session container: {name}")
                            containers_to_remove.append(name)

            except json.JSONDecodeError:
                logger.warning(f"Failed to parse container JSON: {line[:100]}")
                continue

        if containers_to_remove:
            results = await asyncio.gather(*[
                self._remove_container(name)
                for name in containers_to_remove
            ], return_exceptions=True)
            for name, result in zip(containers_to_remove, results):
                if isinstance(result, Exception):
                    logger.warning(f"Failed to remove container {name} during reconcile: {result}")
            removed = sum(1 for r in results if not isinstance(r, Exception))
            logger.info(f"Removed {removed}/{len(containers_to_remove)} container(s) during reconcile")

        if named_env_names:
            logger.info(f"Named env containers present: {', '.join(named_env_names)}")
