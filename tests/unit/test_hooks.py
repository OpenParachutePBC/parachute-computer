"""
Tests for the event-driven hooks system.
"""

import asyncio
from pathlib import Path

import pytest

from parachute.core.hooks.events import BLOCKING_EVENTS, HookEvent
from parachute.core.hooks.models import HookConfig, HookError
from parachute.core.hooks.runner import HookRunner


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def vault_path(tmp_path):
    """Create a vault with hooks directory."""
    vault = tmp_path / "vault"
    vault.mkdir()
    hooks_dir = vault / ".parachute" / "hooks"
    hooks_dir.mkdir(parents=True)
    return vault


@pytest.fixture
def hooks_dir(vault_path):
    return vault_path / ".parachute" / "hooks"


def write_hook(hooks_dir: Path, name: str, events: list[str], code: str = "",
               blocking: bool = False, enabled: bool = True) -> Path:
    """Helper to create a hook script."""
    hook_file = hooks_dir / f"{name}.py"
    config_str = (
        f"HOOK_CONFIG = {{\n"
        f"    'events': {events!r},\n"
        f"    'blocking': {blocking!r},\n"
        f"    'enabled': {enabled!r},\n"
        f"    'description': 'Test hook: {name}',\n"
        f"}}\n\n"
    )
    if not code:
        code = "async def run(context: dict) -> None:\n    pass\n"
    hook_file.write_text(config_str + code)
    return hook_file


# ---------------------------------------------------------------------------
# HookEvent tests
# ---------------------------------------------------------------------------


class TestHookEvent:
    def test_event_count(self):
        assert len(HookEvent) == 14

    def test_session_events(self):
        assert HookEvent.SESSION_CREATED == "session.created"
        assert HookEvent.SESSION_COMPLETED == "session.completed"
        assert HookEvent.SESSION_RESUMED == "session.resumed"

    def test_daily_events(self):
        assert HookEvent.DAILY_ENTRY_CREATED == "daily.entry.created"

    def test_bot_events(self):
        assert HookEvent.BOT_MESSAGE_RECEIVED == "bot.message.received"

    def test_blocking_events(self):
        assert HookEvent.CONTEXT_APPROACHING_LIMIT in BLOCKING_EVENTS
        assert HookEvent.SERVER_STOPPING in BLOCKING_EVENTS
        assert HookEvent.SESSION_COMPLETED not in BLOCKING_EVENTS


# ---------------------------------------------------------------------------
# HookConfig tests
# ---------------------------------------------------------------------------


class TestHookConfig:
    def test_to_dict(self):
        config = HookConfig(
            name="test_hook",
            path=Path("/hooks/test.py"),
            events=["session.completed"],
            blocking=False,
            description="A test hook",
        )
        d = config.to_dict()
        assert d["name"] == "test_hook"
        assert d["events"] == ["session.completed"]
        assert d["blocking"] is False
        assert d["description"] == "A test hook"

    def test_defaults(self):
        config = HookConfig(name="test", path=Path("/test.py"))
        assert config.events == []
        assert config.blocking is False
        assert config.timeout == 30.0
        assert config.enabled is True


class TestHookError:
    def test_to_dict(self):
        err = HookError(
            hook_name="test",
            event="session.completed",
            error="Something failed",
            timestamp="2026-02-05T12:00:00Z",
        )
        d = err.to_dict()
        assert d["hook_name"] == "test"
        assert d["error"] == "Something failed"


# ---------------------------------------------------------------------------
# HookRunner tests
# ---------------------------------------------------------------------------


class TestHookRunnerDiscovery:
    @pytest.mark.asyncio
    async def test_discover_no_directory(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        count = await runner.discover()
        assert count == 0

    @pytest.mark.asyncio
    async def test_discover_empty_directory(self, vault_path, hooks_dir):
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 0

    @pytest.mark.asyncio
    async def test_discover_single_hook(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "test_hook", ["session.completed"])
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 1

    @pytest.mark.asyncio
    async def test_discover_multiple_hooks(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "hook_a", ["session.completed"])
        write_hook(hooks_dir, "hook_b", ["message.received"])
        write_hook(hooks_dir, "hook_c", ["daily.entry.created", "daily.entry.updated"])
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 3

    @pytest.mark.asyncio
    async def test_discover_skips_disabled(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "enabled_hook", ["session.completed"], enabled=True)
        write_hook(hooks_dir, "disabled_hook", ["session.completed"], enabled=False)
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 1

    @pytest.mark.asyncio
    async def test_discover_skips_underscore_files(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "good_hook", ["session.completed"])
        (hooks_dir / "__init__.py").write_text("")
        (hooks_dir / "_private.py").write_text("HOOK_CONFIG = {'events': ['session.completed']}\nasync def run(ctx): pass\n")
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 1

    @pytest.mark.asyncio
    async def test_discover_skips_no_config(self, vault_path, hooks_dir):
        (hooks_dir / "no_config.py").write_text("# No HOOK_CONFIG here\n")
        runner = HookRunner(vault_path=vault_path)
        count = await runner.discover()
        assert count == 0

    @pytest.mark.asyncio
    async def test_auto_detects_blocking(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "memory_hook", ["context.approaching_limit"], blocking=False)
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()
        # context.approaching_limit is in BLOCKING_EVENTS, so should auto-detect
        hooks = runner._hooks.get("context.approaching_limit", [])
        assert len(hooks) == 1
        assert hooks[0].blocking is True


class TestHookRunnerExecution:
    @pytest.mark.asyncio
    async def test_fire_async_hook(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "counter", ["session.completed"],
            code=(
                "results = []\n"
                "async def run(context: dict) -> None:\n"
                "    results.append(context.get('event'))\n"
            ),
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        await runner.fire(HookEvent.SESSION_COMPLETED, {"session_id": "test"})
        # Give async task time to complete
        await asyncio.sleep(0.1)

        module = runner._hook_modules["counter"]
        assert "session.completed" in module.results

    @pytest.mark.asyncio
    async def test_fire_blocking_hook(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "blocker", ["session.completed"],
            code=(
                "results = []\n"
                "async def run(context: dict) -> None:\n"
                "    results.append('ran')\n"
            ),
            blocking=True,
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        await runner.fire("session.completed", {}, blocking=True)

        module = runner._hook_modules["blocker"]
        assert module.results == ["ran"]

    @pytest.mark.asyncio
    async def test_fire_no_hooks_for_event(self, vault_path, hooks_dir):
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()
        # Should not raise
        await runner.fire("nonexistent.event", {})

    @pytest.mark.asyncio
    async def test_fire_with_enum(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "enum_hook", ["server.started"],
            code=(
                "results = []\n"
                "async def run(context: dict) -> None:\n"
                "    results.append(context.get('event'))\n"
            ),
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        await runner.fire(HookEvent.SERVER_STARTED, {})
        await asyncio.sleep(0.1)

        module = runner._hook_modules["enum_hook"]
        assert "server.started" in module.results

    @pytest.mark.asyncio
    async def test_fire_sync_hook(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "sync_hook", ["session.completed"],
            code=(
                "results = []\n"
                "def run(context: dict) -> None:\n"
                "    results.append('sync_ran')\n"
            ),
            blocking=True,
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        await runner.fire("session.completed", {}, blocking=True)

        module = runner._hook_modules["sync_hook"]
        assert module.results == ["sync_ran"]


class TestHookRunnerErrorIsolation:
    @pytest.mark.asyncio
    async def test_error_in_async_hook_doesnt_crash(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "failing_hook", ["session.completed"],
            code="async def run(context): raise ValueError('test error')\n",
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        # Should not raise
        await runner.fire("session.completed", {})
        await asyncio.sleep(0.1)

        errors = runner.get_recent_errors()
        assert len(errors) == 1
        assert "test error" in errors[0]["error"]

    @pytest.mark.asyncio
    async def test_error_in_blocking_hook_doesnt_crash(self, vault_path, hooks_dir):
        write_hook(
            hooks_dir, "failing_blocker", ["session.completed"],
            code="async def run(context): raise RuntimeError('block fail')\n",
            blocking=True,
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        # Should not raise
        await runner.fire("session.completed", {}, blocking=True)

        errors = runner.get_recent_errors()
        assert len(errors) == 1

    @pytest.mark.asyncio
    async def test_timeout_in_blocking_hook(self, vault_path, hooks_dir):
        hook_file = hooks_dir / "slow_hook.py"
        hook_file.write_text(
            "import asyncio\n"
            "HOOK_CONFIG = {\n"
            "    'events': ['session.completed'],\n"
            "    'blocking': True,\n"
            "    'timeout': 0.5,\n"
            "}\n\n"
            "async def run(context):\n"
            "    await asyncio.sleep(10)\n"
        )
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        await runner.fire("session.completed", {}, blocking=True)

        errors = runner.get_recent_errors()
        assert len(errors) == 1
        assert "timed out" in errors[0]["error"]


class TestHookRunnerAPI:
    @pytest.mark.asyncio
    async def test_get_registered_hooks(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "hook_a", ["session.completed"])
        write_hook(hooks_dir, "hook_b", ["message.received", "message.sent"])
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        hooks = runner.get_registered_hooks()
        assert len(hooks) == 2
        names = {h["name"] for h in hooks}
        assert "hook_a" in names
        assert "hook_b" in names

    @pytest.mark.asyncio
    async def test_health_info(self, vault_path, hooks_dir):
        write_hook(hooks_dir, "hook_a", ["session.completed"])
        runner = HookRunner(vault_path=vault_path)
        await runner.discover()

        health = runner.health_info()
        assert health["hooks_count"] == 1
        assert "session.completed" in health["events_registered"]
        assert health["recent_errors_count"] == 0
