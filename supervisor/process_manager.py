"""
Process manager for the Parachute server.

Handles spawning, monitoring, and restarting the main server process.
"""

import asyncio
import logging
import os
import signal
import sys
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


class ProcessState(str, Enum):
    """State of the managed process."""

    STOPPED = "stopped"
    STARTING = "starting"
    RUNNING = "running"
    STOPPING = "stopping"
    FAILED = "failed"
    RESTARTING = "restarting"


@dataclass
class ProcessInfo:
    """Information about the managed process."""

    state: ProcessState = ProcessState.STOPPED
    pid: Optional[int] = None
    started_at: Optional[datetime] = None
    last_health_check: Optional[datetime] = None
    restart_count: int = 0
    last_error: Optional[str] = None
    uptime_seconds: float = 0


@dataclass
class ProcessConfig:
    """Configuration for the managed process."""

    vault_path: Path
    port: int = 3333
    host: str = "0.0.0.0"
    health_check_interval: int = 10  # seconds
    health_check_timeout: int = 5  # seconds
    max_restart_attempts: int = 5
    restart_delay: int = 2  # seconds
    log_file: Optional[Path] = None


class ProcessManager:
    """
    Manages the lifecycle of the Parachute server process.

    Features:
    - Process spawning and monitoring
    - Health check polling
    - Automatic restart on failure
    - Graceful shutdown
    """

    def __init__(self, config: ProcessConfig):
        """Initialize process manager."""
        self.config = config
        self.process: Optional[asyncio.subprocess.Process] = None
        self.info = ProcessInfo()
        self._health_check_task: Optional[asyncio.Task] = None
        self._should_run = False
        self._restart_attempts = 0

    async def start(self) -> bool:
        """Start the server process."""
        if self.info.state in [ProcessState.RUNNING, ProcessState.STARTING]:
            logger.warning("Process already running or starting")
            return False

        self.info.state = ProcessState.STARTING
        self._should_run = True

        try:
            # Build command
            python = sys.executable
            cmd = [
                python,
                "-m",
                "parachute.server",
            ]

            # Environment
            env = os.environ.copy()
            env["VAULT_PATH"] = str(self.config.vault_path)
            env["PORT"] = str(self.config.port)
            env["HOST"] = self.config.host

            # Start process
            logger.info(f"Starting server: {' '.join(cmd)}")

            self.process = await asyncio.create_subprocess_exec(
                *cmd,
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            self.info.pid = self.process.pid
            self.info.started_at = datetime.utcnow()
            self.info.state = ProcessState.RUNNING
            self._restart_attempts = 0

            # Start health check task
            self._health_check_task = asyncio.create_task(self._health_check_loop())

            # Start output reader
            asyncio.create_task(self._read_output())

            logger.info(f"Server started with PID {self.info.pid}")
            return True

        except Exception as e:
            self.info.state = ProcessState.FAILED
            self.info.last_error = str(e)
            logger.error(f"Failed to start server: {e}")
            return False

    async def stop(self, timeout: float = 30.0) -> bool:
        """Stop the server process gracefully."""
        if self.info.state == ProcessState.STOPPED:
            return True

        self._should_run = False
        self.info.state = ProcessState.STOPPING

        # Cancel health check
        if self._health_check_task:
            self._health_check_task.cancel()
            try:
                await self._health_check_task
            except asyncio.CancelledError:
                pass

        if not self.process:
            self.info.state = ProcessState.STOPPED
            return True

        try:
            # Send SIGTERM
            self.process.terminate()

            try:
                await asyncio.wait_for(self.process.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                # Force kill
                logger.warning("Process didn't stop gracefully, killing")
                self.process.kill()
                await self.process.wait()

            self.info.state = ProcessState.STOPPED
            self.info.pid = None
            self.process = None

            logger.info("Server stopped")
            return True

        except Exception as e:
            self.info.last_error = str(e)
            logger.error(f"Error stopping server: {e}")
            return False

    async def restart(self) -> bool:
        """Restart the server process."""
        self.info.state = ProcessState.RESTARTING
        self.info.restart_count += 1

        logger.info("Restarting server...")

        await self.stop()
        await asyncio.sleep(self.config.restart_delay)
        return await self.start()

    async def _health_check_loop(self) -> None:
        """Periodically check server health."""
        import httpx

        while self._should_run:
            try:
                await asyncio.sleep(self.config.health_check_interval)

                if not self._should_run:
                    break

                # Check if process is still running
                if self.process and self.process.returncode is not None:
                    logger.error(f"Process exited with code {self.process.returncode}")
                    await self._handle_crash()
                    continue

                # HTTP health check
                try:
                    async with httpx.AsyncClient() as client:
                        response = await client.get(
                            f"http://{self.config.host}:{self.config.port}/api/health",
                            timeout=self.config.health_check_timeout,
                        )
                        if response.status_code == 200:
                            self.info.last_health_check = datetime.utcnow()
                            if self.info.started_at:
                                self.info.uptime_seconds = (
                                    datetime.utcnow() - self.info.started_at
                                ).total_seconds()
                        else:
                            logger.warning(f"Health check failed: {response.status_code}")

                except httpx.TimeoutException:
                    logger.warning("Health check timed out")
                except httpx.ConnectError:
                    logger.warning("Health check connection failed")
                    # Process might have crashed
                    if self.process and self.process.returncode is not None:
                        await self._handle_crash()

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Health check error: {e}")

    async def _handle_crash(self) -> None:
        """Handle server crash."""
        self.info.state = ProcessState.FAILED
        self.info.last_error = f"Process exited with code {self.process.returncode if self.process else 'unknown'}"

        if not self._should_run:
            return

        self._restart_attempts += 1

        if self._restart_attempts > self.config.max_restart_attempts:
            logger.error(
                f"Max restart attempts ({self.config.max_restart_attempts}) exceeded"
            )
            self._should_run = False
            return

        logger.info(
            f"Attempting restart ({self._restart_attempts}/{self.config.max_restart_attempts})"
        )

        await asyncio.sleep(self.config.restart_delay * self._restart_attempts)

        if self._should_run:
            await self.start()

    async def _read_output(self) -> None:
        """Read and log process output."""
        if not self.process:
            return

        async def read_stream(stream, level):
            while True:
                line = await stream.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    logger.log(level, f"[server] {text}")

        if self.process.stdout:
            asyncio.create_task(read_stream(self.process.stdout, logging.INFO))
        if self.process.stderr:
            asyncio.create_task(read_stream(self.process.stderr, logging.ERROR))

    def get_info(self) -> dict:
        """Get process information as dict."""
        return {
            "state": self.info.state.value,
            "pid": self.info.pid,
            "started_at": self.info.started_at.isoformat() if self.info.started_at else None,
            "last_health_check": (
                self.info.last_health_check.isoformat()
                if self.info.last_health_check
                else None
            ),
            "restart_count": self.info.restart_count,
            "last_error": self.info.last_error,
            "uptime_seconds": self.info.uptime_seconds,
        }
