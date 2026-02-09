"""Tests for daemon management (launchd, systemd, PID fallback)."""

import os
import plistlib
import signal
import sys
from pathlib import Path
from unittest.mock import MagicMock, call, patch

import pytest

from parachute.daemon import (
    LAUNCHD_LABEL,
    SYSTEMD_UNIT,
    LaunchdDaemon,
    PidDaemon,
    SystemdDaemon,
    get_daemon_manager,
)


@pytest.fixture
def vault(tmp_path):
    vault_path = tmp_path / "vault"
    vault_path.mkdir()
    (vault_path / ".parachute").mkdir()
    (vault_path / ".parachute" / "logs").mkdir()
    return vault_path


@pytest.fixture
def config():
    return {"port": 3333, "host": "0.0.0.0"}


class TestGetDaemonManager:
    def test_macos_returns_launchd(self, vault, config):
        with patch("parachute.daemon.sys") as mock_sys:
            mock_sys.platform = "darwin"
            mock_sys.executable = sys.executable
            manager = get_daemon_manager(vault, config)
            assert isinstance(manager, LaunchdDaemon)

    def test_linux_with_systemd_returns_systemd(self, vault, config, tmp_path):
        with patch("parachute.daemon.sys") as mock_sys:
            mock_sys.platform = "linux"
            mock_sys.executable = sys.executable
            with patch("parachute.daemon.Path.home", return_value=tmp_path):
                (tmp_path / ".config" / "systemd").mkdir(parents=True)
                manager = get_daemon_manager(vault, config)
                assert isinstance(manager, SystemdDaemon)

    def test_fallback_returns_pid(self, vault, config):
        with patch("parachute.daemon.sys") as mock_sys:
            mock_sys.platform = "freebsd"
            mock_sys.executable = sys.executable
            manager = get_daemon_manager(vault, config)
            assert isinstance(manager, PidDaemon)


class TestLaunchdDaemon:
    def test_plist_path(self, vault, config):
        d = LaunchdDaemon(vault, config)
        assert d.plist_path.name == f"{LAUNCHD_LABEL}.plist"
        assert "LaunchAgents" in str(d.plist_path)

    def test_build_plist_contents(self, vault, config):
        d = LaunchdDaemon(vault, config)
        plist = d._build_plist()
        assert plist["Label"] == LAUNCHD_LABEL
        assert plist["RunAtLoad"] is True
        assert plist["KeepAlive"] is True
        assert "--port" in plist["ProgramArguments"]
        assert "3333" in plist["ProgramArguments"]
        assert plist["EnvironmentVariables"]["VAULT_PATH"] == str(vault)
        assert plist["EnvironmentVariables"]["PYTHONUNBUFFERED"] == "1"

    def test_build_plist_custom_port(self, vault):
        config = {"port": 5555, "host": "127.0.0.1"}
        d = LaunchdDaemon(vault, config)
        plist = d._build_plist()
        assert "5555" in plist["ProgramArguments"]
        assert "127.0.0.1" in plist["ProgramArguments"]

    def test_install_writes_plist(self, vault, config, tmp_path):
        d = LaunchdDaemon(vault, config)
        d.plist_path = tmp_path / "test.plist"
        with patch("subprocess.run"):
            d.install()
        assert d.plist_path.exists()
        with open(d.plist_path, "rb") as f:
            data = plistlib.load(f)
        assert data["Label"] == LAUNCHD_LABEL

    def test_is_installed(self, vault, config, tmp_path):
        d = LaunchdDaemon(vault, config)
        d.plist_path = tmp_path / "test.plist"
        assert not d.is_installed()
        d.plist_path.write_bytes(b"test")
        assert d.is_installed()

    def test_uninstall_removes_plist(self, vault, config, tmp_path):
        d = LaunchdDaemon(vault, config)
        d.plist_path = tmp_path / "test.plist"
        d.plist_path.write_bytes(b"test")
        with patch("subprocess.run"):
            d.uninstall()
        assert not d.plist_path.exists()


class TestSystemdDaemon:
    def test_unit_path(self, vault, config):
        d = SystemdDaemon(vault, config)
        assert d.unit_path.name == SYSTEMD_UNIT

    def test_build_unit_contents(self, vault, config):
        d = SystemdDaemon(vault, config)
        unit = d._build_unit()
        assert "Description=Parachute AI Server" in unit
        assert f"--port {config['port']}" in unit
        assert f"VAULT_PATH={vault}" in unit
        assert "PYTHONUNBUFFERED=1" in unit
        assert "Restart=on-failure" in unit
        assert "WantedBy=default.target" in unit

    def test_install_writes_unit(self, vault, config, tmp_path):
        d = SystemdDaemon(vault, config)
        d.unit_path = tmp_path / "parachute.service"
        d.unit_dir = tmp_path
        with patch("subprocess.run"):
            d.install()
        assert d.unit_path.exists()
        content = d.unit_path.read_text()
        assert "Parachute AI Server" in content

    def test_is_installed(self, vault, config, tmp_path):
        d = SystemdDaemon(vault, config)
        d.unit_path = tmp_path / "test.service"
        assert not d.is_installed()
        d.unit_path.write_text("test")
        assert d.is_installed()


class TestPidDaemon:
    def test_install_creates_marker(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        assert d._installed_marker.exists()

    def test_is_installed(self, vault, config):
        d = PidDaemon(vault, config)
        assert not d.is_installed()
        d.install()
        assert d.is_installed()

    def test_uninstall_removes_marker(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        with patch("parachute.daemon._process_alive", return_value=False):
            d.uninstall()
        assert not d.is_installed()

    def test_status_not_running(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        status = d.status()
        assert status["installed"] is True
        assert status["running"] is False
        assert status["type"] == "pid"

    def test_status_with_stale_pid(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        d.pid_file.write_text("99999999")
        with patch("parachute.daemon._process_alive", return_value=False):
            status = d.status()
        assert status["running"] is False
        assert not d.pid_file.exists()  # Stale PID cleaned up

    def test_status_with_active_pid(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        d.pid_file.write_text("12345")
        with patch("parachute.daemon._process_alive", return_value=True):
            status = d.status()
        assert status["running"] is True
        assert status["pid"] == 12345

    def test_stop_sends_sigterm(self, vault, config):
        d = PidDaemon(vault, config)
        d.pid_file.parent.mkdir(parents=True, exist_ok=True)
        d.pid_file.write_text("12345")

        with patch("parachute.daemon._process_alive", side_effect=[True, False]):
            with patch("os.kill") as mock_kill:
                d.stop()
                mock_kill.assert_called_with(12345, signal.SIGTERM)

    def test_stop_escalates_to_sigkill(self, vault, config):
        d = PidDaemon(vault, config)
        d.pid_file.parent.mkdir(parents=True, exist_ok=True)
        d.pid_file.write_text("12345")

        # Process stays alive after SIGTERM
        with patch("parachute.daemon._process_alive", return_value=True):
            with patch("os.kill") as mock_kill:
                with patch("time.sleep"):
                    d.stop()
                # Should have sent SIGTERM then SIGKILL
                mock_kill.assert_any_call(12345, signal.SIGTERM)
                mock_kill.assert_any_call(12345, signal.SIGKILL)

    def test_start_writes_pid_file(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()

        mock_proc = MagicMock()
        mock_proc.pid = 42
        with patch("subprocess.Popen", return_value=mock_proc):
            d.start()
        assert d.pid_file.read_text() == "42"

    def test_start_skips_if_already_running(self, vault, config):
        d = PidDaemon(vault, config)
        d.install()
        d.pid_file.write_text("12345")

        with patch("parachute.daemon._process_alive", return_value=True):
            with patch("subprocess.Popen") as mock_popen:
                d.start()
                mock_popen.assert_not_called()
