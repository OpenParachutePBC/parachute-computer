"""
Unit tests for the 4 extracted Orchestrator phase methods.

Tests cover:
  - _save_attachments()
  - _discover_capabilities()
  - _run_trusted() (happy path + error handling)
  - _run_sandboxed() (Docker-unavailable early exit)
"""

import asyncio
import base64
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.core.orchestrator import (
    CapabilityBundle,
    Orchestrator,
)
from parachute.models.session import (
    Session,
    SessionPermissions,
    SessionSource,
    TrustLevel,
)

_NOW = datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Helpers / Fixtures
# ---------------------------------------------------------------------------


async def _aiter(items):
    """Module-level async iterator helper."""
    for item in items:
        yield item


def _make_session(
    session_id: str = "test-session-001",
    source: SessionSource = SessionSource.PARACHUTE,
    trust_level: TrustLevel | None = None,
    container_id: str | None = None,
) -> Session:
    """Return a minimal Session for testing."""
    perms = SessionPermissions(
        trust_level=TrustLevel.DIRECT,
        allowed_paths=[],
    )
    return Session(
        id=session_id,
        module="chat",
        source=source,
        permissions=perms,
        trust_level=trust_level,
        container_id=container_id,
        created_at=_NOW,
        last_accessed=_NOW,
    )


def _make_orchestrator(parachute_dir: Path) -> Orchestrator:
    """Return an Orchestrator with mocked dependencies."""
    session_store = AsyncMock()
    settings = MagicMock()
    settings.claude_code_oauth_token = "test-token"
    settings.default_model = None
    settings.include_user_plugins = False
    settings.plugin_dirs = []

    return Orchestrator(
        parachute_dir=parachute_dir,
        session_store=session_store,
        settings=settings,
    )


def _make_caps(**overrides) -> CapabilityBundle:
    defaults = dict(
        resolved_mcps=None,
        plugin_dirs=[],
        agents_dict=None,
        effective_trust="direct",
        tool_guidance="",
        warnings=[],
    )
    defaults.update(overrides)
    return CapabilityBundle(**defaults)


def _make_resume_info() -> MagicMock:
    ri = MagicMock()
    ri.model_dump.return_value = {}
    return ri


# ---------------------------------------------------------------------------
# _save_attachments
# ---------------------------------------------------------------------------


class TestSaveAttachments:
    def setup_method(self):
        self.orch = _make_orchestrator(Path.home())

    def test_empty_attachments_returns_empty_string(self):
        block, failures = self.orch._save_attachments([])
        assert block == ""
        assert failures == []

    def test_skips_attachment_without_base64_data(self):
        block, failures = self.orch._save_attachments(
            [
                {"type": "image", "fileName": "test.png"},
            ]
        )
        assert block == ""
        assert failures == []

    def test_saves_image_and_returns_markdown(self, tmp_path, monkeypatch):
        # Redirect Chat/assets into tmp_path
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        png_bytes = b"\x89PNG\r\n"
        b64 = base64.b64encode(png_bytes).decode()

        block, failures = self.orch._save_attachments(
            [
                {"type": "image", "fileName": "photo.png", "base64Data": b64},
            ]
        )

        assert failures == []
        assert "photo.png" in block
        assert "![" in block  # markdown image syntax

    def test_saves_text_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        text_bytes = b"hello world"
        b64 = base64.b64encode(text_bytes).decode()

        block, failures = self.orch._save_attachments(
            [
                {"type": "text", "fileName": "notes.txt", "base64Data": b64},
            ]
        )

        assert failures == []
        assert "notes.txt" in block

    def test_records_failure_on_bad_base64(self, tmp_path, monkeypatch):
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        block, failures = self.orch._save_attachments(
            [
                {
                    "type": "image",
                    "fileName": "bad.png",
                    "base64Data": "NOT_VALID_BASE64!!!",
                },
            ]
        )
        assert len(failures) == 1
        assert "bad.png" in failures[0]
        assert "[Failed to attach: bad.png]" in block

    def test_multiple_attachments_joined(self, tmp_path, monkeypatch):
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        b64 = base64.b64encode(b"data").decode()
        block, failures = self.orch._save_attachments(
            [
                {"type": "text", "fileName": "a.txt", "base64Data": b64},
                {"type": "text", "fileName": "b.txt", "base64Data": b64},
            ]
        )

        assert "a.txt" in block
        assert "b.txt" in block
        assert failures == []


# ---------------------------------------------------------------------------
# _discover_capabilities
# ---------------------------------------------------------------------------


class TestDiscoverCapabilities:
    def setup_method(self):
        self.orch = _make_orchestrator(Path.home())

    @pytest.mark.asyncio
    async def test_returns_capability_bundle(self):
        agent = MagicMock()
        agent.mcp_servers = []
        session = _make_session()

        with (
            patch(
                "parachute.core.orchestrator.load_mcp_servers",
                new_callable=AsyncMock,
                return_value={},
            ),
            patch("parachute.core.orchestrator.resolve_mcp_servers", return_value=None),
        ):
            bundle = await self.orch._discover_capabilities(agent, session, None)

        assert isinstance(bundle, CapabilityBundle)
        assert bundle.effective_trust == TrustLevel.DIRECT.value
        assert bundle.warnings == []

    @pytest.mark.asyncio
    async def test_mcp_load_failure_adds_warning(self):
        agent = MagicMock()
        agent.mcp_servers = []
        session = _make_session()

        with (
            patch(
                "parachute.core.orchestrator.load_mcp_servers",
                new_callable=AsyncMock,
                side_effect=RuntimeError("MCP boom"),
            ),
        ):
            bundle = await self.orch._discover_capabilities(agent, session, None)

        assert bundle.resolved_mcps is None
        assert len(bundle.warnings) == 1
        assert bundle.warnings[0]["type"] == "warning"

    @pytest.mark.asyncio
    async def test_explicit_trust_level_overrides_session(self):
        """Client-supplied trust_level overrides the session's stored trust level."""
        agent = MagicMock()
        agent.mcp_servers = []
        # Session stored as direct; client overrides to sandboxed
        session = _make_session(trust_level=TrustLevel.DIRECT)

        with (
            patch(
                "parachute.core.orchestrator.load_mcp_servers",
                new_callable=AsyncMock,
                return_value={},
            ),
            patch("parachute.core.orchestrator.resolve_mcp_servers", return_value=None),
        ):
            bundle = await self.orch._discover_capabilities(agent, session, "sandboxed")

        assert bundle.effective_trust == "sandboxed"


# ---------------------------------------------------------------------------
# _run_trusted
# ---------------------------------------------------------------------------


class TestRunTrusted:
    def setup_method(self):
        self.orch = _make_orchestrator(Path.home())
        self._session = _make_session()
        self._permission_handler = self._make_permission_handler(self._session)

    def _make_permission_handler(self, session):
        ph = MagicMock()
        ph.session = session
        ph.create_sdk_callback.return_value = None
        ph.get_pending.return_value = []
        return ph

    def _call_run_trusted(self, **overrides):
        """Build default _run_trusted kwargs and apply overrides."""
        defaults = dict(
            session=self._session,
            caps=_make_caps(),
            actual_message="test",
            effective_prompt="",
            effective_cwd=Path.home(),
            resume_id=None,
            model=None,
            claude_token="tok",
            message_queue=asyncio.Queue(),
            interrupt=MagicMock(is_interrupted=False),
            is_new=False,
            message="test",
            working_directory=None,
            agent_type=None,
            resume_info=_make_resume_info(),
            start_time=0.0,
        )
        defaults.update(overrides)
        return self.orch._run_trusted(**defaults)

    @pytest.mark.asyncio
    async def test_yields_done_event_on_success(self):
        sdk_events = [
            {
                "type": "assistant",
                "session_id": "real-sid",
                "message": {
                    "content": [{"type": "text", "text": "Hello"}],
                    "model": "claude-opus-4",
                },
            },
            {"type": "result", "session_id": "real-sid", "result": "Hello"},
        ]

        with (
            patch(
                "parachute.core.orchestrator.query_streaming",
                return_value=_aiter(sdk_events),
            ),
            patch.object(
                self.orch.session_manager,
                "finalize_session",
                new_callable=AsyncMock,
                return_value=self._session,
            ),
            patch.object(
                self.orch.session_manager,
                "increment_message_count",
                new_callable=AsyncMock,
            ),
        ):
            events = []
            async for e in self._call_run_trusted(is_new=True):
                events.append(e)

        assert "done" in [e["type"] for e in events]

    @pytest.mark.asyncio
    async def test_yields_typed_error_on_exception(self):
        with patch(
            "parachute.core.orchestrator.query_streaming",
            side_effect=RuntimeError("boom"),
        ):
            events = []
            async for e in self._call_run_trusted():
                events.append(e)

        types = [e["type"] for e in events]
        assert "error" in types or "typed_error" in types

    @pytest.mark.asyncio
    async def test_yields_aborted_and_raises_on_cancelled(self):
        with patch(
            "parachute.core.orchestrator.query_streaming",
            side_effect=asyncio.CancelledError(),
        ):
            events = []
            with pytest.raises(asyncio.CancelledError):
                async for e in self._call_run_trusted():
                    events.append(e)

        assert "aborted" in [e["type"] for e in events]


# ---------------------------------------------------------------------------
# _run_sandboxed — Docker-unavailable path
# ---------------------------------------------------------------------------


class TestRunSandboxed:
    def setup_method(self):
        self.orch = _make_orchestrator(Path.home())

    @pytest.mark.asyncio
    async def test_docker_available_calls_sandbox_run_session(self):
        """When Docker IS available, delegate to _sandbox.run_session."""
        session = _make_session()
        caps = _make_caps(effective_trust="sandboxed")

        self.orch._sandbox.is_available = AsyncMock(return_value=True)
        self.orch._sandbox.image_exists = AsyncMock(return_value=True)
        self.orch._sandbox.run_session = MagicMock(
            return_value=_aiter(
                [
                    {"type": "done", "sessionId": "sandbox-sid-1"},
                ]
            )
        )

        with patch.object(
            self.orch.session_manager,
            "finalize_session",
            new_callable=AsyncMock,
            return_value=session,
        ):
            events = []
            async for e in self.orch._run_sandboxed(
                session=session,
                caps=caps,
                actual_message="hi",
                effective_prompt="",
                effective_working_dir=None,
                is_new=True,
                model=None,
                message="hi",
                agent_type=None,
                captured_model=None,
            ):
                events.append(e)

        self.orch._sandbox.run_session.assert_called_once()

    @pytest.mark.asyncio
    async def test_missing_sandbox_image_yields_error(self):
        """When Docker is available but image is missing, yields ErrorEvent."""
        session = _make_session()
        caps = _make_caps(effective_trust="sandboxed")

        self.orch._sandbox.is_available = AsyncMock(return_value=True)
        self.orch._sandbox.image_exists = AsyncMock(return_value=False)

        events = []
        async for e in self.orch._run_sandboxed(
            session=session,
            caps=caps,
            actual_message="hi",
            effective_prompt="",
            effective_working_dir=None,
            is_new=True,
            model=None,
            message="hi",
            agent_type=None,
            captured_model=None,
        ):
            events.append(e)

        assert "error" in [e["type"] for e in events]
