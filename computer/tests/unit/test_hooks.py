"""
Tests for the internal event bus (hooks system).

Note: User-facing hook discovery from vault/.parachute/hooks/ was removed
in the agentic ecosystem consolidation (Feb 2026). User hooks are now
handled by the Claude Agent SDK via .claude/settings.json.

These tests cover:
- HookEvent enum
- HookConfig / HookError models
- HookRunner as internal event bus (programmatic registration + fire)
"""

import asyncio
from pathlib import Path

import pytest

from parachute.core.hooks.events import BLOCKING_EVENTS, HookEvent
from parachute.core.hooks.models import HookConfig, HookError
from parachute.core.hooks.runner import HookRunner


# ---------------------------------------------------------------------------
# HookEvent tests
# ---------------------------------------------------------------------------


class TestHookEvent:
    def test_event_count(self):
        assert len(HookEvent) == 16

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
# HookRunner tests — internal event bus
# ---------------------------------------------------------------------------


class TestHookRunnerDiscoverNoop:
    """Discover is now a no-op (user hook discovery removed)."""

    @pytest.mark.asyncio
    async def test_discover_returns_zero(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        count = await runner.discover()
        assert count == 0

    @pytest.mark.asyncio
    async def test_discover_with_hooks_dir_still_returns_zero(self, tmp_path):
        """Even if .parachute/hooks/ exists, discover does nothing."""
        hooks_dir = tmp_path / ".parachute" / "hooks"
        hooks_dir.mkdir(parents=True)
        (hooks_dir / "test_hook.py").write_text(
            "HOOK_CONFIG = {'events': ['session.completed']}\n"
            "async def run(ctx): pass\n"
        )
        runner = HookRunner(vault_path=tmp_path)
        count = await runner.discover()
        assert count == 0


class TestHookRunnerFireWithNoHooks:
    """Fire with no registered hooks should be a no-op."""

    @pytest.mark.asyncio
    async def test_fire_no_hooks(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        # Should not raise
        await runner.fire("session.completed", {})

    @pytest.mark.asyncio
    async def test_fire_with_enum(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        # Should not raise
        await runner.fire(HookEvent.SERVER_STARTED, {})


class TestHookRunnerAPI:
    """Test API methods on empty runner."""

    @pytest.mark.asyncio
    async def test_get_registered_hooks_empty(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        hooks = runner.get_registered_hooks()
        assert hooks == []

    @pytest.mark.asyncio
    async def test_health_info_empty(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        health = runner.health_info()
        assert health["hooks_count"] == 0
        assert health["events_registered"] == []
        assert health["recent_errors_count"] == 0

    @pytest.mark.asyncio
    async def test_get_recent_errors_empty(self, tmp_path):
        runner = HookRunner(vault_path=tmp_path)
        errors = runner.get_recent_errors()
        assert errors == []
