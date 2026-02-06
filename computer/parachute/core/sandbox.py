"""
Docker sandbox for agent execution.

Provides per-agent Docker containers with scoped filesystem mounts
and credential propagation for the Claude Agent SDK.

Fallback: When Docker is not available, degrades to VAULT trust level
(process-level isolation with restricted permissions).
"""

import asyncio
import json
import logging
import shutil
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


class DockerSandbox:
    """Manages Docker containers for sandboxed agent execution."""

    def __init__(self, vault_path: Path, claude_token: Optional[str] = None):
        self.vault_path = vault_path
        self.claude_token = claude_token
        self._docker_available: Optional[bool] = None

    async def is_available(self) -> bool:
        """Check if Docker is installed and running."""
        if self._docker_available is not None:
            return self._docker_available

        if not shutil.which("docker"):
            logger.warning("Docker not found in PATH")
            self._docker_available = False
            return False

        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "info",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=5.0)
            self._docker_available = proc.returncode == 0
            if not self._docker_available:
                logger.warning("Docker daemon not running")
            return self._docker_available
        except (asyncio.TimeoutError, OSError):
            logger.warning("Docker check timed out or failed")
            self._docker_available = False
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
            # Resolve pattern to actual path (no glob expansion in Docker mounts)
            full_path = self.vault_path / path_pattern.rstrip("/**/*").rstrip("/*")
            if full_path.exists():
                container_path = f"/vault/{path_pattern.rstrip('/**/*').rstrip('/*')}"
                mounts.extend(["-v", f"{full_path}:{container_path}:rw"])

        # If no specific paths, mount entire vault read-only
        if not config.allowed_paths:
            mounts.extend(["-v", f"{self.vault_path}:/vault:ro"])

        return mounts

    def _build_run_args(self, config: AgentSandboxConfig) -> list[str]:
        """Build complete docker run arguments."""
        args = [
            "docker", "run",
            "--rm",
            "--name", f"parachute-sandbox-{config.session_id[:8]}",
            "--memory", CONTAINER_MEMORY_LIMIT,
            "--cpus", CONTAINER_CPU_LIMIT,
        ]

        # Network isolation
        if not config.network_enabled:
            args.extend(["--network", "none"])

        # Volume mounts
        args.extend(self._build_mounts(config))

        # Environment
        args.extend([
            "-e", f"PARACHUTE_SESSION_ID={config.session_id}",
            "-e", f"PARACHUTE_AGENT_TYPE={config.agent_type}",
        ])

        # Pass Claude token as env var (no credential files needed)
        if self.claude_token:
            args.extend(["-e", f"CLAUDE_CODE_OAUTH_TOKEN={self.claude_token}"])

        # Image
        args.append(SANDBOX_IMAGE)

        return args

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

        args = self._build_run_args(config)
        # Pass message as stdin
        args.extend(["--input", json.dumps({"message": message})])

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            # Stream stdout line by line (JSONL events)
            async def read_events():
                while True:
                    line = await proc.stdout.readline()
                    if not line:
                        break
                    try:
                        event = json.loads(line.decode().strip())
                        yield event
                    except json.JSONDecodeError:
                        logger.debug(f"Non-JSON output from sandbox: {line.decode().strip()}")

            async for event in read_events():
                yield event

            # Wait for completion with timeout
            try:
                await asyncio.wait_for(proc.wait(), timeout=config.timeout_seconds)
            except asyncio.TimeoutError:
                logger.error(f"Sandbox timed out for session {config.session_id}")
                proc.kill()
                yield {"type": "error", "message": "Sandbox execution timed out"}

            if proc.returncode and proc.returncode != 0:
                stderr = await proc.stderr.read()
                logger.error(f"Sandbox exited with code {proc.returncode}: {stderr.decode()}")
                yield {"type": "error", "message": f"Sandbox error (exit {proc.returncode})"}

        except OSError as e:
            logger.error(f"Failed to start sandbox: {e}")
            yield {"type": "error", "message": f"Failed to start sandbox: {e}"}

    def health_info(self) -> dict:
        """Return Docker health info for /health endpoint."""
        return {
            "docker_available": self._docker_available,
            "sandbox_image": SANDBOX_IMAGE,
        }
