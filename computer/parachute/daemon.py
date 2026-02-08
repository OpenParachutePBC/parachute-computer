"""
Daemon management for Parachute server.

Supports launchd (macOS), systemd (Linux), and PID-file fallback.
"""

import logging
import os
import plistlib
import signal
import subprocess
import sys
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

LAUNCHD_LABEL = "io.openparachute.server"
SYSTEMD_UNIT = "parachute.service"


class DaemonManager(ABC):
    """Base class for platform-specific daemon management."""

    def __init__(self, vault_path: Path, config: dict[str, Any]):
        self.vault_path = vault_path
        self.config = config
        self.port = config.get("port", 3333)
        self.host = config.get("host", "0.0.0.0")

    def _find_python(self) -> str:
        """Find the Python executable in the current venv."""
        return sys.executable

    def _find_repo_dir(self) -> Path:
        """Find the repo root directory from the package location."""
        import parachute as pkg

        pkg_dir = Path(pkg.__file__).parent  # parachute/
        return pkg_dir.parent                # computer/

    @abstractmethod
    def install(self) -> None:
        """Install the daemon configuration."""

    @abstractmethod
    def uninstall(self) -> None:
        """Remove daemon configuration."""

    @abstractmethod
    def start(self) -> None:
        """Start the daemon."""

    @abstractmethod
    def stop(self) -> None:
        """Stop the daemon."""

    def restart(self) -> None:
        """Restart the daemon."""
        self.stop()
        time.sleep(1)
        self.start()

    @abstractmethod
    def status(self) -> dict[str, Any]:
        """Get daemon status. Returns dict with 'running', 'pid', 'installed', 'type'."""

    @abstractmethod
    def is_installed(self) -> bool:
        """Check if daemon is installed."""


class LaunchdDaemon(DaemonManager):
    """macOS launchd daemon management."""

    def __init__(self, vault_path: Path, config: dict[str, Any]):
        super().__init__(vault_path, config)
        self.plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCHD_LABEL}.plist"
        # Use ~/Library/Logs/ — launchd can't write to external volumes
        self.log_dir = Path.home() / "Library" / "Logs" / "Parachute"

    def _build_plist(self) -> dict:
        """Build the launchd plist dictionary."""
        python = self._find_python()
        self.log_dir.mkdir(parents=True, exist_ok=True)

        return {
            "Label": LAUNCHD_LABEL,
            "ProgramArguments": [
                python, "-m", "uvicorn",
                "parachute.server:app",
                "--host", self.host,
                "--port", str(self.port),
            ],
            "EnvironmentVariables": {
                "VAULT_PATH": str(self.vault_path),
                "PARACHUTE_CONFIG": str(self.vault_path / ".parachute" / "config.yaml"),
                "PYTHONUNBUFFERED": "1",
                # launchd has minimal PATH — add standard locations for docker, git, etc.
                "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            },
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 10,
            "StandardOutPath": str(self.log_dir / "stdout.log"),
            "StandardErrorPath": str(self.log_dir / "stderr.log"),
            "WorkingDirectory": str(self._find_repo_dir()),
        }

    def install(self) -> None:
        self.plist_path.parent.mkdir(parents=True, exist_ok=True)

        # Unload existing if present
        if self.plist_path.exists():
            try:
                subprocess.run(
                    ["launchctl", "bootout", f"gui/{os.getuid()}", str(self.plist_path)],
                    capture_output=True, timeout=10,
                )
            except Exception:
                pass

        plist_data = self._build_plist()
        with open(self.plist_path, "wb") as f:
            plistlib.dump(plist_data, f)

        logger.info(f"Installed launchd plist: {self.plist_path}")

    def uninstall(self) -> None:
        if self.plist_path.exists():
            self.stop()
            self.plist_path.unlink()
            logger.info(f"Removed launchd plist: {self.plist_path}")

    def start(self) -> None:
        if not self.plist_path.exists():
            raise RuntimeError("Daemon not installed. Run 'parachute install' first.")

        result = subprocess.run(
            ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(self.plist_path)],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            # May already be loaded — try kickstart instead
            result2 = subprocess.run(
                ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{LAUNCHD_LABEL}"],
                capture_output=True, text=True, timeout=10,
            )
            if result2.returncode != 0:
                raise RuntimeError(f"Failed to start daemon: {result.stderr} / {result2.stderr}")

    def stop(self) -> None:
        try:
            subprocess.run(
                ["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCHD_LABEL}"],
                capture_output=True, text=True, timeout=10,
            )
        except Exception as e:
            logger.warning(f"Error stopping daemon: {e}")

    def status(self) -> dict[str, Any]:
        info: dict[str, Any] = {
            "type": "launchd",
            "installed": self.is_installed(),
            "running": False,
        }

        try:
            result = subprocess.run(
                ["launchctl", "print", f"gui/{os.getuid()}/{LAUNCHD_LABEL}"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                info["loaded"] = True
                # Parse state and PID from output
                for line in result.stdout.splitlines():
                    line = line.strip()
                    if line.startswith("pid = "):
                        try:
                            pid = int(line.split("=")[1].strip())
                            info["pid"] = pid
                            info["running"] = True
                        except ValueError:
                            pass
                    elif line.startswith("state = "):
                        info["state"] = line.split("=")[1].strip()
                    elif "last exit code" in line:
                        info["last_exit"] = line.strip()

                # If no PID found, it's loaded but not running
                if "pid" not in info:
                    info["running"] = False
        except Exception:
            pass

        return info

    def is_installed(self) -> bool:
        return self.plist_path.exists()


class SystemdDaemon(DaemonManager):
    """Linux systemd user service management."""

    def __init__(self, vault_path: Path, config: dict[str, Any]):
        super().__init__(vault_path, config)
        self.unit_dir = Path.home() / ".config" / "systemd" / "user"
        self.unit_path = self.unit_dir / SYSTEMD_UNIT
        # Use XDG state dir — avoids issues with vault on network/external mounts
        self.log_dir = Path.home() / ".local" / "state" / "parachute" / "logs"

    def _build_unit(self) -> str:
        """Build the systemd unit file content."""
        python = self._find_python()
        self.log_dir.mkdir(parents=True, exist_ok=True)

        return f"""[Unit]
Description=Parachute AI Server
After=network.target

[Service]
Type=simple
ExecStart={python} -m uvicorn parachute.server:app --host {self.host} --port {self.port}
WorkingDirectory={self._find_repo_dir()}
Environment=VAULT_PATH={self.vault_path}
Environment=PARACHUTE_CONFIG={self.vault_path / '.parachute' / 'config.yaml'}
Environment=PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=5
StandardOutput=append:{self.log_dir / 'stdout.log'}
StandardError=append:{self.log_dir / 'stderr.log'}

[Install]
WantedBy=default.target
"""

    def install(self) -> None:
        self.unit_dir.mkdir(parents=True, exist_ok=True)
        self.unit_path.write_text(self._build_unit())
        subprocess.run(
            ["systemctl", "--user", "daemon-reload"],
            capture_output=True, timeout=10,
        )
        subprocess.run(
            ["systemctl", "--user", "enable", SYSTEMD_UNIT],
            capture_output=True, timeout=10,
        )
        logger.info(f"Installed systemd unit: {self.unit_path}")

    def uninstall(self) -> None:
        self.stop()
        subprocess.run(
            ["systemctl", "--user", "disable", SYSTEMD_UNIT],
            capture_output=True, timeout=10,
        )
        if self.unit_path.exists():
            self.unit_path.unlink()
        subprocess.run(
            ["systemctl", "--user", "daemon-reload"],
            capture_output=True, timeout=10,
        )
        logger.info(f"Removed systemd unit: {self.unit_path}")

    def start(self) -> None:
        result = subprocess.run(
            ["systemctl", "--user", "start", SYSTEMD_UNIT],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to start: {result.stderr}")

    def stop(self) -> None:
        subprocess.run(
            ["systemctl", "--user", "stop", SYSTEMD_UNIT],
            capture_output=True, timeout=10,
        )

    def restart(self) -> None:
        result = subprocess.run(
            ["systemctl", "--user", "restart", SYSTEMD_UNIT],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to restart: {result.stderr}")

    def status(self) -> dict[str, Any]:
        info: dict[str, Any] = {
            "type": "systemd",
            "installed": self.is_installed(),
            "running": False,
        }

        try:
            result = subprocess.run(
                ["systemctl", "--user", "is-active", SYSTEMD_UNIT],
                capture_output=True, text=True, timeout=5,
            )
            info["running"] = result.stdout.strip() == "active"

            if info["running"]:
                pid_result = subprocess.run(
                    ["systemctl", "--user", "show", SYSTEMD_UNIT, "--property=MainPID"],
                    capture_output=True, text=True, timeout=5,
                )
                for line in pid_result.stdout.splitlines():
                    if line.startswith("MainPID="):
                        try:
                            info["pid"] = int(line.split("=")[1])
                        except ValueError:
                            pass
        except Exception:
            pass

        return info

    def is_installed(self) -> bool:
        return self.unit_path.exists()


class PidDaemon(DaemonManager):
    """Fallback PID-file based daemon for systems without launchd/systemd."""

    def __init__(self, vault_path: Path, config: dict[str, Any]):
        super().__init__(vault_path, config)
        self.pid_file = vault_path / ".parachute" / "server.pid"
        # Use same location as systemd on Linux, macOS logs on macOS
        if sys.platform == "darwin":
            self.log_dir = Path.home() / "Library" / "Logs" / "Parachute"
        else:
            self.log_dir = Path.home() / ".local" / "state" / "parachute" / "logs"
        self._installed_marker = vault_path / ".parachute" / ".daemon_installed"

    def install(self) -> None:
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._installed_marker.touch()
        logger.info("PID daemon installed (no service manager)")

    def uninstall(self) -> None:
        self.stop()
        if self._installed_marker.exists():
            self._installed_marker.unlink()
        if self.pid_file.exists():
            self.pid_file.unlink()

    def start(self) -> None:
        # Check if already running
        if self.pid_file.exists():
            try:
                pid = int(self.pid_file.read_text().strip())
                if _process_alive(pid):
                    logger.info(f"Already running with PID {pid}")
                    return
            except (ValueError, OSError):
                pass
            self.pid_file.unlink()

        python = self._find_python()
        self.log_dir.mkdir(parents=True, exist_ok=True)

        stdout_log = open(self.log_dir / "stdout.log", "a")
        stderr_log = open(self.log_dir / "stderr.log", "a")

        env = os.environ.copy()
        env["VAULT_PATH"] = str(self.vault_path)
        env["PYTHONUNBUFFERED"] = "1"

        proc = subprocess.Popen(
            [python, "-m", "uvicorn", "parachute.server:app",
             "--host", self.host, "--port", str(self.port)],
            stdout=stdout_log,
            stderr=stderr_log,
            env=env,
            start_new_session=True,
        )

        self.pid_file.write_text(str(proc.pid))
        logger.info(f"Started with PID {proc.pid}")

    def stop(self) -> None:
        if not self.pid_file.exists():
            return

        try:
            pid = int(self.pid_file.read_text().strip())
            if _process_alive(pid):
                os.kill(pid, signal.SIGTERM)
                # Wait briefly for clean shutdown
                for _ in range(10):
                    if not _process_alive(pid):
                        break
                    time.sleep(0.5)
                else:
                    os.kill(pid, signal.SIGKILL)
        except (ValueError, OSError) as e:
            logger.warning(f"Error stopping PID daemon: {e}")
        finally:
            if self.pid_file.exists():
                self.pid_file.unlink()

    def status(self) -> dict[str, Any]:
        info: dict[str, Any] = {
            "type": "pid",
            "installed": self.is_installed(),
            "running": False,
        }

        if self.pid_file.exists():
            try:
                pid = int(self.pid_file.read_text().strip())
                if _process_alive(pid):
                    info["running"] = True
                    info["pid"] = pid
                else:
                    # Stale PID file
                    self.pid_file.unlink()
            except (ValueError, OSError):
                pass

        return info

    def is_installed(self) -> bool:
        return self._installed_marker.exists()


def _process_alive(pid: int) -> bool:
    """Check if a process is alive."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def get_daemon_manager(vault_path: Path, config: dict[str, Any]) -> DaemonManager:
    """Factory: detect platform and return appropriate daemon manager."""
    if sys.platform == "darwin":
        return LaunchdDaemon(vault_path, config)
    elif sys.platform == "linux":
        # Check if systemd is available
        if (Path.home() / ".config" / "systemd").exists() or Path("/run/systemd/system").exists():
            return SystemdDaemon(vault_path, config)
    # Fallback
    return PidDaemon(vault_path, config)
