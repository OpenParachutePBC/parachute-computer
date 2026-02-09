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
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncGenerator, Optional

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


class DockerSandbox:
    """Manages Docker containers for sandboxed agent execution."""

    # Re-check Docker availability every 60 seconds
    _CACHE_TTL = 60

    def __init__(self, vault_path: Path, claude_token: Optional[str] = None):
        self.vault_path = vault_path
        self.claude_token = claude_token
        self._docker_available: Optional[bool] = None
        self._checked_at: float = 0

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

    def _build_run_args(self, config: AgentSandboxConfig) -> tuple[list[str], Optional[str], Optional[str]]:
        """Build complete docker run arguments.

        Returns (args, env_file_path, caps_file_path) where temp files
        must be cleaned up after the container starts.
        """
        # Validate session_id is safe for Docker --name
        if not re.match(r'^[a-zA-Z0-9_-]+$', config.session_id):
            raise ValueError(f"Invalid session_id format: {config.session_id[:20]}")

        args = [
            "docker", "run",
            "--rm",
            "-i",  # Interactive mode: accept stdin for message passing
            "--name", f"parachute-sandbox-{config.session_id[:8]}",
            "--memory", CONTAINER_MEMORY_LIMIT,
            "--cpus", CONTAINER_CPU_LIMIT,
        ]

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])

        # Volume mounts
        args.extend(self._build_mounts(config))

        # Environment variables via --env-file to avoid token exposure in process table
        env_file_path = None
        caps_file_path = None
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
        except Exception:
            # Clean up on error
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
            except Exception:
                os.unlink(caps_file_path)
                caps_file_path = None
                logger.warning("Failed to write capabilities config for sandbox")

        # Image
        args.append(SANDBOX_IMAGE)

        return args, env_file_path, caps_file_path

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

        args, env_file_path, caps_file_path = self._build_run_args(config)

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            # Note: env file cleanup is deferred to the finally block.
            # Docker needs time to read the --env-file after process start.

            # Guard against None pipes (subprocess failed to start fully)
            if proc.stdin is None or proc.stdout is None:
                yield {"type": "error", "message": "Failed to open pipes to sandbox container"}
                return

            # Pass message via stdin (Docker -i flag enables this)
            proc.stdin.write(json.dumps({"message": message}).encode() + b"\n")
            await proc.stdin.drain()
            proc.stdin.close()

            # Stream stdout line by line (JSONL events) with timeout enforcement
            # Each readline has a per-chunk timeout, plus overall deadline
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
                        timeout=min(remaining, 180),  # Per-chunk cap of 3 min
                    )
                except asyncio.TimeoutError:
                    timed_out = True
                    break
                if not line:
                    break
                try:
                    event = json.loads(line.decode().strip())
                    yield event
                except json.JSONDecodeError:
                    logger.debug(f"Non-JSON output from sandbox: {line.decode().strip()}")

            if timed_out:
                logger.error(f"Sandbox timed out for session {config.session_id}")
                proc.kill()
                yield {"type": "error", "message": "Sandbox execution timed out"}
                return

            # Wait for process exit
            try:
                await asyncio.wait_for(proc.wait(), timeout=10)
            except asyncio.TimeoutError:
                proc.kill()

            if proc.returncode and proc.returncode != 0:
                stderr_data = b""
                if proc.stderr:
                    stderr_data = await proc.stderr.read()
                logger.error(f"Sandbox exited with code {proc.returncode}: {stderr_data.decode()}")
                yield {"type": "error", "message": f"Sandbox error (exit {proc.returncode})"}

        except OSError as e:
            logger.error(f"Failed to start sandbox: {e}")
            yield {"type": "error", "message": f"Failed to start sandbox: {e}"}
        finally:
            # Ensure temp files are cleaned up even on error
            for tmp_file in (env_file_path, caps_file_path):
                if tmp_file:
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
