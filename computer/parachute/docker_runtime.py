"""
Docker runtime detection and lifecycle management.

Detects installed Docker runtimes (OrbStack, Colima, Docker Desktop, Rancher Desktop)
and provides start/stop/status operations. Used by the supervisor to manage Docker
as a dependency — the main server never starts Docker itself.

macOS-only for now. Linux uses systemd for Docker daemon management (different pattern).
"""

import asyncio
import logging
import shutil
import time
from pathlib import Path
from typing import Optional

from pydantic import BaseModel

logger = logging.getLogger(__name__)

# Subprocess timeout for quick checks (docker info, which, etc.)
_CHECK_TIMEOUT = 5.0

# Subprocess timeout for start commands (they return quickly; readiness is polled separately)
_START_TIMEOUT = 15.0

# Default readiness polling timeout
_READY_TIMEOUT = 45.0
_READY_INTERVAL = 1.0


class DockerRuntime(BaseModel):
    """A detected Docker runtime provider."""

    name: str  # "orbstack", "colima", "docker_desktop", "rancher_desktop"
    display_name: str  # "OrbStack", "Colima", etc.
    available: bool  # Binary/app bundle exists on disk
    running: bool = False  # Daemon is responding to `docker info`


# Registry of known runtimes in preference order.
# Each entry: (name, display_name, detection_fn, start_cmd, stop_cmd)
_RUNTIME_SPECS: list[dict] = [
    {
        "name": "orbstack",
        "display_name": "OrbStack",
        "detect": lambda: shutil.which("orb") is not None,
        "start_cmd": ["orb", "start"],
        "stop_cmd": ["orb", "stop"],
    },
    {
        "name": "colima",
        "display_name": "Colima",
        "detect": lambda: shutil.which("colima") is not None,
        "start_cmd": ["colima", "start"],
        "stop_cmd": ["colima", "stop"],
    },
    {
        "name": "docker_desktop",
        "display_name": "Docker Desktop",
        "detect": lambda: Path("/Applications/Docker.app").exists(),
        "start_cmd": ["open", "-a", "Docker"],
        "stop_cmd": ["osascript", "-e", 'quit app "Docker"'],
    },
    {
        "name": "rancher_desktop",
        "display_name": "Rancher Desktop",
        "detect": lambda: Path("/Applications/Rancher Desktop.app").exists(),
        "start_cmd": ["open", "-a", "Rancher Desktop"],
        "stop_cmd": ["osascript", "-e", 'quit app "Rancher Desktop"'],
    },
]


class DockerRuntimeRegistry:
    """Detect and manage Docker runtime providers.

    Thread-safe: all methods use asyncio.to_thread for blocking subprocess calls.
    """

    def __init__(self):
        self._specs = _RUNTIME_SPECS

    async def detect_all(self) -> list[DockerRuntime]:
        """Detect all installed Docker runtimes.

        Returns a list of DockerRuntime objects with availability info.
        Does NOT check if the daemon is running (use is_daemon_running for that).
        """
        runtimes = []
        for spec in self._specs:
            available = await asyncio.to_thread(spec["detect"])
            runtimes.append(DockerRuntime(
                name=spec["name"],
                display_name=spec["display_name"],
                available=available,
            ))
        return runtimes

    async def detect_preferred(
        self, config_override: Optional[str] = None
    ) -> Optional[DockerRuntime]:
        """Detect the preferred available runtime.

        If config_override is set (e.g., "orbstack"), use that runtime if available.
        Otherwise, return the first available runtime in preference order.
        """
        all_runtimes = await self.detect_all()

        if config_override:
            for rt in all_runtimes:
                if rt.name == config_override and rt.available:
                    return rt
            # Config override not found — fall through to auto-detect
            logger.warning(
                f"Configured docker_runtime '{config_override}' not available, "
                f"falling back to auto-detection"
            )

        for rt in all_runtimes:
            if rt.available:
                return rt

        return None

    async def is_daemon_running(self) -> bool:
        """Check if the Docker daemon is responding."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "info",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await asyncio.wait_for(proc.wait(), timeout=_CHECK_TIMEOUT)
            return proc.returncode == 0
        except (asyncio.TimeoutError, OSError, FileNotFoundError):
            return False

    async def start(self, runtime: DockerRuntime) -> bool:
        """Start a Docker runtime.

        Returns True if the start command was issued successfully.
        Note: This does NOT wait for readiness — use poll_ready() for that.
        """
        spec = self._get_spec(runtime.name)
        if spec is None:
            logger.error(f"Unknown runtime: {runtime.name}")
            return False

        start_cmd = spec["start_cmd"]
        logger.info(f"Starting Docker runtime: {runtime.display_name} ({' '.join(start_cmd)})")

        try:
            proc = await asyncio.create_subprocess_exec(
                *start_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            # Most start commands return quickly (non-blocking).
            # Colima blocks until ready, so we use a generous timeout.
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=_START_TIMEOUT
            )
            if proc.returncode != 0:
                logger.error(
                    f"Failed to start {runtime.display_name}: "
                    f"exit {proc.returncode}, stderr={stderr.decode()[:200]}"
                )
                return False
            logger.info(f"Start command issued for {runtime.display_name}")
            return True
        except asyncio.TimeoutError:
            # For non-blocking start commands this shouldn't happen.
            # For colima, timeout means it's still starting — that's OK,
            # poll_ready() will handle the rest.
            logger.warning(f"Start command timed out for {runtime.display_name} — may still be starting")
            return True
        except (OSError, FileNotFoundError) as e:
            logger.error(f"Failed to start {runtime.display_name}: {e}")
            return False

    async def stop(self, runtime: DockerRuntime) -> bool:
        """Stop a Docker runtime.

        Returns True if the stop command was issued successfully.
        """
        spec = self._get_spec(runtime.name)
        if spec is None:
            logger.error(f"Unknown runtime: {runtime.name}")
            return False

        stop_cmd = spec["stop_cmd"]
        logger.info(f"Stopping Docker runtime: {runtime.display_name}")

        try:
            # For osascript commands, we need shell=True
            if stop_cmd[0] == "osascript":
                proc = await asyncio.create_subprocess_shell(
                    " ".join(stop_cmd),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
            else:
                proc = await asyncio.create_subprocess_exec(
                    *stop_cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
            await asyncio.wait_for(proc.communicate(), timeout=_START_TIMEOUT)
            return proc.returncode == 0
        except (asyncio.TimeoutError, OSError, FileNotFoundError) as e:
            logger.error(f"Failed to stop {runtime.display_name}: {e}")
            return False

    async def poll_ready(
        self,
        timeout: float = _READY_TIMEOUT,
        interval: float = _READY_INTERVAL,
    ) -> bool:
        """Poll until Docker daemon is ready or timeout is reached.

        Returns True if daemon became ready, False on timeout.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            if await self.is_daemon_running():
                logger.info("Docker daemon is ready")
                return True
            await asyncio.sleep(interval)

        logger.warning(f"Docker readiness timeout after {timeout}s")
        return False

    def _get_spec(self, name: str) -> Optional[dict]:
        """Get the runtime spec by name."""
        for spec in self._specs:
            if spec["name"] == name:
                return spec
        return None
