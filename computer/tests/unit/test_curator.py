"""
Tests for curator.py — background context agent.

Covers:
- _should_update() cadence (exchanges {1, 3, 5}, every 10th after that)
- observe() skips when exchange not in cadence
- observe() respects title_source == "user" guard (informs curator prompt)
- observe() writes curator_last_run metadata after a run
- observe() persists curator_session_id from the system event on first run
- observe() resumes with existing curator_session_id on subsequent runs
- observe() never raises — fire-and-forget safety
"""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.core.curator import _should_update, observe


# ---------------------------------------------------------------------------
# _should_update cadence tests (ported from test_session_summarizer.py)
# ---------------------------------------------------------------------------


class TestShouldUpdate:
    def test_fires_on_exchange_1(self):
        assert _should_update(1) is True

    def test_fires_on_exchange_3(self):
        assert _should_update(3) is True

    def test_fires_on_exchange_5(self):
        assert _should_update(5) is True

    def test_skips_exchange_2(self):
        assert _should_update(2) is False

    def test_skips_exchange_4(self):
        assert _should_update(4) is False

    def test_skips_exchange_6(self):
        assert _should_update(6) is False

    def test_skips_exchange_7_through_9(self):
        for n in [7, 8, 9]:
            assert _should_update(n) is False

    def test_fires_on_exchange_10(self):
        assert _should_update(10) is True

    def test_skips_exchange_11_through_19(self):
        for n in range(11, 20):
            assert _should_update(n) is False

    def test_fires_on_exchange_20(self):
        assert _should_update(20) is True

    def test_fires_on_exchange_30(self):
        assert _should_update(30) is True

    def test_skips_exchange_25(self):
        assert _should_update(25) is False


# ---------------------------------------------------------------------------
# observe() helpers
# ---------------------------------------------------------------------------


def _make_mock_db(
    session_title: str = None,
    title_source: str = None,
    curator_session_id: str = None,
    session_exists: bool = True,
):
    """Build a minimal mock database for observe() tests."""
    db = MagicMock()

    if session_exists:
        mock_session = MagicMock()
        mock_session.title = session_title
        meta = {}
        if title_source:
            meta["title_source"] = title_source
        if curator_session_id:
            meta["curator_session_id"] = curator_session_id
        mock_session.metadata = meta
        db.get_session = AsyncMock(return_value=mock_session)
    else:
        db.get_session = AsyncMock(return_value=None)

    db.update_session = AsyncMock()
    return db


async def _empty_stream():
    """Async generator that yields nothing — curator skips with no events."""
    return
    yield  # pragma: no cover — makes this a generator


async def _stream_with_system_and_tool(session_id: str, tool_name: str = "update_summary"):
    """Yields a system event (new session) and a tool_use assistant event."""
    yield {"type": "system", "session_id": "curator-sdk-session-xyz"}
    yield {
        "type": "assistant",
        "message": {
            "content": [
                {
                    "type": "tool_use",
                    "name": tool_name,
                    "input": {"summary": "Exchange 1: User asked about Python."},
                }
            ]
        },
    }
    yield {"type": "result"}


async def _stream_with_title_tool():
    """Yields a system event and an update_title tool call."""
    yield {"type": "system", "session_id": "curator-sdk-session-abc"}
    yield {
        "type": "assistant",
        "message": {
            "content": [
                {
                    "type": "tool_use",
                    "name": "update_title",
                    "input": {"title": "Python Async Patterns"},
                },
                {
                    "type": "tool_use",
                    "name": "update_summary",
                    "input": {"summary": "Discussed Python async."},
                },
            ]
        },
    }
    yield {"type": "result"}


async def _stream_resume(curator_session_id: str):
    """Yields events for a resumed session (no system event — already have session_id)."""
    yield {
        "type": "assistant",
        "message": {
            "content": [
                {
                    "type": "tool_use",
                    "name": "log_activity",
                    "input": {"summary": "Exchange 3: Explored generators.", "exchange_number": 3},
                }
            ]
        },
    }
    yield {"type": "result"}


# ---------------------------------------------------------------------------
# observe() tests
# ---------------------------------------------------------------------------


class TestObserve:
    @pytest.mark.asyncio
    async def test_skips_on_non_cadence_exchange(self, tmp_path):
        """observe() does not call query_streaming on non-cadence exchanges."""
        db = _make_mock_db()
        with patch(
            "parachute.core.curator.query_streaming",
            new_callable=AsyncMock,
        ) as mock_qs:
            await observe(
                session_id="sess_001abc1234567890",
                message="Hello",
                result_text="Hi",
                tool_calls=[],
                exchange_number=2,  # not in cadence
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        mock_qs.assert_not_called()
        db.update_session.assert_not_called()

    @pytest.mark.asyncio
    async def test_skips_when_session_not_found(self, tmp_path):
        """observe() exits gracefully when the session doesn't exist."""
        db = _make_mock_db(session_exists=False)
        with patch(
            "parachute.core.curator.query_streaming",
            new_callable=AsyncMock,
        ) as mock_qs:
            await observe(
                session_id="sess_doesnotexist12",
                message="Hello",
                result_text="Hi",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        mock_qs.assert_not_called()

    @pytest.mark.asyncio
    async def test_persists_curator_session_id_on_first_run(self, tmp_path):
        """On first run, new curator_session_id from system event is saved."""
        db = _make_mock_db(session_title="Test", curator_session_id=None)

        with patch(
            "parachute.core.curator.query_streaming",
            return_value=_stream_with_system_and_tool("sess_001abc1234567890"),
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="What is Python?",
                result_text="Python is a language.",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        db.update_session.assert_called_once()
        call_args = db.update_session.call_args
        saved_meta = call_args[0][1].metadata
        assert saved_meta["curator_session_id"] == "curator-sdk-session-xyz"
        assert "curator_last_run" in saved_meta

    @pytest.mark.asyncio
    async def test_resumes_with_existing_curator_session_id(self, tmp_path):
        """On subsequent runs, observe() passes resume= to query_streaming."""
        db = _make_mock_db(curator_session_id="existing-curator-session")

        captured_kwargs: dict = {}

        async def mock_query_streaming(**kwargs):
            captured_kwargs.update(kwargs)
            async for event in _stream_resume("existing-curator-session"):
                yield event

        with patch(
            "parachute.core.curator.query_streaming",
            side_effect=mock_query_streaming,
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Tell me more",
                result_text="Here's more.",
                tool_calls=[],
                exchange_number=3,
                session_title="Python Chat",
                title_source="ai",
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        assert captured_kwargs.get("resume") == "existing-curator-session"

    @pytest.mark.asyncio
    async def test_captures_new_title_from_tool_call(self, tmp_path):
        """curator_last_run.new_title is set when curator calls update_title."""
        db = _make_mock_db(session_title=None)

        with patch(
            "parachute.core.curator.query_streaming",
            return_value=_stream_with_title_tool(),
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Help with async",
                result_text="Here's async explained.",
                tool_calls=["Read"],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        saved_meta = db.update_session.call_args[0][1].metadata
        assert saved_meta["curator_last_run"]["new_title"] == "Python Async Patterns"
        assert "update_title" in saved_meta["curator_last_run"]["actions"]

    @pytest.mark.asyncio
    async def test_curator_last_run_written_after_run(self, tmp_path):
        """curator_last_run metadata is always written after a successful run."""
        db = _make_mock_db()

        with patch(
            "parachute.core.curator.query_streaming",
            return_value=_stream_with_system_and_tool("sess_001abc1234567890"),
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Hello",
                result_text="Hi",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        saved_meta = db.update_session.call_args[0][1].metadata
        last_run = saved_meta["curator_last_run"]
        assert "ts" in last_run
        assert last_run["exchange_number"] == 1
        assert isinstance(last_run["actions"], list)

    @pytest.mark.asyncio
    async def test_user_title_noted_in_prompt(self, tmp_path):
        """When title_source == 'user', the prompt tells curator not to update title."""
        db = _make_mock_db(session_title="My Title", title_source="user")

        captured_prompt: list[str] = []

        async def mock_query_streaming(**kwargs):
            captured_prompt.append(kwargs.get("prompt", ""))
            async for event in _stream_with_system_and_tool("sess_001abc1234567890"):
                yield event

        with patch(
            "parachute.core.curator.query_streaming",
            side_effect=mock_query_streaming,
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Question",
                result_text="Answer",
                tool_calls=[],
                exchange_number=1,
                session_title="My Title",
                title_source="user",
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        assert captured_prompt, "query_streaming was not called"
        assert "user-set" in captured_prompt[0]
        assert "do NOT call update_title" in captured_prompt[0]

    @pytest.mark.asyncio
    async def test_never_raises_on_query_streaming_exception(self, tmp_path):
        """observe() catches all exceptions and never raises."""
        db = _make_mock_db()

        async def exploding_stream(**kwargs):
            raise RuntimeError("SDK exploded")
            yield  # pragma: no cover

        with patch(
            "parachute.core.curator.query_streaming",
            side_effect=exploding_stream,
        ):
            # Must not raise
            await observe(
                session_id="sess_001abc1234567890",
                message="Question",
                result_text="Answer",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

    @pytest.mark.asyncio
    async def test_never_raises_on_db_exception(self, tmp_path):
        """observe() catches DB errors and never raises."""
        db = _make_mock_db()
        db.update_session = AsyncMock(side_effect=Exception("DB gone"))

        with patch(
            "parachute.core.curator.query_streaming",
            return_value=_stream_with_system_and_tool("sess_001abc1234567890"),
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Question",
                result_text="Answer",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

    @pytest.mark.asyncio
    async def test_model_haiku_passed_to_query_streaming(self, tmp_path):
        """observe() always uses claude-haiku-4-5-20251001."""
        db = _make_mock_db()

        captured_kwargs: dict = {}

        async def mock_qs(**kwargs):
            captured_kwargs.update(kwargs)
            async for event in _empty_stream():
                yield event

        with patch(
            "parachute.core.curator.query_streaming",
            side_effect=mock_qs,
        ):
            await observe(
                session_id="sess_001abc1234567890",
                message="Hello",
                result_text="Hi",
                tool_calls=[],
                exchange_number=1,
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        assert captured_kwargs.get("model") == "claude-haiku-4-5-20251001"
        assert captured_kwargs.get("use_claude_code_preset") is False
        assert captured_kwargs.get("setting_sources") == []
        assert captured_kwargs.get("permission_mode") == "bypassPermissions"
