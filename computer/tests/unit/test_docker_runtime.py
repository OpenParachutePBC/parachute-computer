"""
Tests for Docker runtime detection and lifecycle management.

All subprocess calls are mocked — no Docker required.
"""

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.docker_runtime import DockerRuntimeRegistry, DockerRuntime


class TestDetectAll:
    @pytest.mark.asyncio
    async def test_detects_orbstack_when_available(self):
        """OrbStack detected when `orb` binary is in PATH."""
        registry = DockerRuntimeRegistry()

        with patch("parachute.docker_runtime.shutil.which", side_effect=lambda x: "/opt/homebrew/bin/orb" if x == "orb" else None):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                runtimes = await registry.detect_all()

        orbstack = next(rt for rt in runtimes if rt.name == "orbstack")
        assert orbstack.available is True
        assert orbstack.display_name == "OrbStack"

    @pytest.mark.asyncio
    async def test_detects_nothing_when_nothing_installed(self):
        """No runtimes detected when nothing is installed."""
        registry = DockerRuntimeRegistry()

        with patch("parachute.docker_runtime.shutil.which", return_value=None):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                runtimes = await registry.detect_all()

        assert all(not rt.available for rt in runtimes)

    @pytest.mark.asyncio
    async def test_detects_docker_desktop_via_app_bundle(self):
        """Docker Desktop detected via /Applications/Docker.app."""
        registry = DockerRuntimeRegistry()

        def mock_exists(self_path):
            return str(self_path) == "/Applications/Docker.app"

        with patch("parachute.docker_runtime.shutil.which", return_value=None):
            with patch("parachute.docker_runtime.Path.exists", mock_exists):
                runtimes = await registry.detect_all()

        dd = next(rt for rt in runtimes if rt.name == "docker_desktop")
        assert dd.available is True
        assert dd.display_name == "Docker Desktop"

    @pytest.mark.asyncio
    async def test_multiple_runtimes_detected(self):
        """Multiple runtimes can be detected simultaneously."""
        registry = DockerRuntimeRegistry()

        def mock_which(cmd):
            return f"/usr/local/bin/{cmd}" if cmd in ("orb", "colima") else None

        with patch("parachute.docker_runtime.shutil.which", side_effect=mock_which):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                runtimes = await registry.detect_all()

        available = [rt for rt in runtimes if rt.available]
        assert len(available) == 2
        names = {rt.name for rt in available}
        assert names == {"orbstack", "colima"}


class TestDetectPreferred:
    @pytest.mark.asyncio
    async def test_orbstack_preferred_over_colima(self):
        """OrbStack is preferred when both are available (preference order)."""
        registry = DockerRuntimeRegistry()

        def mock_which(cmd):
            return f"/usr/local/bin/{cmd}" if cmd in ("orb", "colima") else None

        with patch("parachute.docker_runtime.shutil.which", side_effect=mock_which):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                preferred = await registry.detect_preferred()

        assert preferred is not None
        assert preferred.name == "orbstack"

    @pytest.mark.asyncio
    async def test_config_override_selects_colima(self):
        """Config override selects colima even when OrbStack is available."""
        registry = DockerRuntimeRegistry()

        def mock_which(cmd):
            return f"/usr/local/bin/{cmd}" if cmd in ("orb", "colima") else None

        with patch("parachute.docker_runtime.shutil.which", side_effect=mock_which):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                preferred = await registry.detect_preferred(config_override="colima")

        assert preferred is not None
        assert preferred.name == "colima"

    @pytest.mark.asyncio
    async def test_config_override_falls_back_when_not_available(self):
        """Falls back to auto-detect when config override is not available."""
        registry = DockerRuntimeRegistry()

        with patch("parachute.docker_runtime.shutil.which", side_effect=lambda x: "/opt/homebrew/bin/orb" if x == "orb" else None):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                preferred = await registry.detect_preferred(config_override="colima")

        assert preferred is not None
        assert preferred.name == "orbstack"  # Falls back to first available

    @pytest.mark.asyncio
    async def test_returns_none_when_nothing_available(self):
        """Returns None when no runtimes are available."""
        registry = DockerRuntimeRegistry()

        with patch("parachute.docker_runtime.shutil.which", return_value=None):
            with patch("parachute.docker_runtime.Path.exists", return_value=False):
                preferred = await registry.detect_preferred()

        assert preferred is None


class TestIsDaemonRunning:
    @pytest.mark.asyncio
    async def test_daemon_running_returns_true(self):
        """Returns True when docker info succeeds."""
        registry = DockerRuntimeRegistry()

        mock_proc = AsyncMock()
        mock_proc.returncode = 0
        mock_proc.wait = AsyncMock(return_value=0)

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await registry.is_daemon_running()

        assert result is True

    @pytest.mark.asyncio
    async def test_daemon_not_running_returns_false(self):
        """Returns False when docker info fails."""
        registry = DockerRuntimeRegistry()

        mock_proc = AsyncMock()
        mock_proc.returncode = 1
        mock_proc.wait = AsyncMock(return_value=1)

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await registry.is_daemon_running()

        assert result is False

    @pytest.mark.asyncio
    async def test_daemon_timeout_returns_false(self):
        """Returns False when docker info times out (daemon hanging)."""
        registry = DockerRuntimeRegistry()

        mock_proc = AsyncMock()
        mock_proc.wait = AsyncMock(side_effect=asyncio.TimeoutError())

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", return_value=mock_proc):
            with patch("parachute.docker_runtime.asyncio.wait_for", side_effect=asyncio.TimeoutError()):
                result = await registry.is_daemon_running()

        assert result is False

    @pytest.mark.asyncio
    async def test_docker_not_installed_returns_false(self):
        """Returns False when docker binary doesn't exist."""
        registry = DockerRuntimeRegistry()

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", side_effect=FileNotFoundError()):
            result = await registry.is_daemon_running()

        assert result is False


class TestStart:
    @pytest.mark.asyncio
    async def test_start_orbstack_success(self):
        """Starting OrbStack issues `orb start` and returns True."""
        registry = DockerRuntimeRegistry()
        runtime = DockerRuntime(name="orbstack", display_name="OrbStack", available=True)

        mock_proc = AsyncMock()
        mock_proc.returncode = 0
        mock_proc.communicate = AsyncMock(return_value=(b"", b""))

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", return_value=mock_proc) as mock_exec:
            result = await registry.start(runtime)

        assert result is True
        mock_exec.assert_called_once_with(
            "orb", "start",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

    @pytest.mark.asyncio
    async def test_start_failure_returns_false(self):
        """Returns False when start command fails."""
        registry = DockerRuntimeRegistry()
        runtime = DockerRuntime(name="orbstack", display_name="OrbStack", available=True)

        mock_proc = AsyncMock()
        mock_proc.returncode = 1
        mock_proc.communicate = AsyncMock(return_value=(b"", b"error"))

        with patch("parachute.docker_runtime.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await registry.start(runtime)

        assert result is False

    @pytest.mark.asyncio
    async def test_start_unknown_runtime_returns_false(self):
        """Returns False for an unknown runtime name."""
        registry = DockerRuntimeRegistry()
        runtime = DockerRuntime(name="unknown", display_name="Unknown", available=True)

        result = await registry.start(runtime)
        assert result is False


class TestPollReady:
    @pytest.mark.asyncio
    async def test_immediate_ready(self):
        """Returns True immediately when daemon is already running."""
        registry = DockerRuntimeRegistry()
        registry.is_daemon_running = AsyncMock(return_value=True)

        result = await registry.poll_ready(timeout=5.0, interval=0.1)
        assert result is True

    @pytest.mark.asyncio
    async def test_becomes_ready_after_retries(self):
        """Returns True after daemon becomes ready on second check."""
        registry = DockerRuntimeRegistry()
        call_count = 0

        async def mock_is_running():
            nonlocal call_count
            call_count += 1
            return call_count >= 2

        registry.is_daemon_running = mock_is_running

        result = await registry.poll_ready(timeout=5.0, interval=0.01)
        assert result is True
        assert call_count == 2

    @pytest.mark.asyncio
    async def test_timeout_returns_false(self):
        """Returns False when daemon never becomes ready."""
        registry = DockerRuntimeRegistry()
        registry.is_daemon_running = AsyncMock(return_value=False)

        result = await registry.poll_ready(timeout=0.05, interval=0.01)
        assert result is False
