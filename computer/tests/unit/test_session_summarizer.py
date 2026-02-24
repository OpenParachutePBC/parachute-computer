"""
Tests for session_summarizer.py — server-side title/summary generation.

Covers:
- _should_update() cadence (exchanges {1, 3, 5}, every 10th after that)
- summarize_session() skips when exchange not in cadence
- summarize_session() respects title_source == "user" guard
- summarize_session() writes title + summary when appropriate
- summarize_session() never raises — fire-and-forget safety
- Daily summarizer session cache (get/save)
"""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.core.session_summarizer import (
    _should_update,
    get_daily_summarizer_session,
    save_daily_summarizer_session,
    summarize_session,
)


# ---------------------------------------------------------------------------
# _should_update cadence tests
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
# Daily summarizer session cache tests
# ---------------------------------------------------------------------------


class TestDailySummarizerSessionCache:
    @pytest.mark.asyncio
    async def test_returns_none_when_no_cache_file(self, tmp_path):
        result = await get_daily_summarizer_session(tmp_path, "2026-02-23")
        assert result is None

    @pytest.mark.asyncio
    async def test_save_and_retrieve_session_id(self, tmp_path):
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_abc123")
        result = await get_daily_summarizer_session(tmp_path, "2026-02-23")
        assert result == "sess_abc123"

    @pytest.mark.asyncio
    async def test_returns_none_for_different_date(self, tmp_path):
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_abc123")
        result = await get_daily_summarizer_session(tmp_path, "2026-02-24")
        assert result is None

    @pytest.mark.asyncio
    async def test_overwrites_existing_session_for_same_date(self, tmp_path):
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_first")
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_second")
        result = await get_daily_summarizer_session(tmp_path, "2026-02-23")
        assert result == "sess_second"

    @pytest.mark.asyncio
    async def test_preserves_other_dates(self, tmp_path):
        await save_daily_summarizer_session(tmp_path, "2026-02-22", "sess_day1")
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_day2")
        assert await get_daily_summarizer_session(tmp_path, "2026-02-22") == "sess_day1"
        assert await get_daily_summarizer_session(tmp_path, "2026-02-23") == "sess_day2"

    @pytest.mark.asyncio
    async def test_cache_file_is_valid_json(self, tmp_path):
        await save_daily_summarizer_session(tmp_path, "2026-02-23", "sess_xyz")
        cache_path = tmp_path / "Daily" / ".activity" / ".activity_summarizer_sessions.json"
        data = json.loads(cache_path.read_text())
        assert data == {"2026-02-23": "sess_xyz"}

    @pytest.mark.asyncio
    async def test_returns_none_on_corrupted_cache(self, tmp_path):
        cache_dir = tmp_path / "Daily" / ".activity"
        cache_dir.mkdir(parents=True)
        (cache_dir / ".activity_summarizer_sessions.json").write_text("not valid json{{{")
        result = await get_daily_summarizer_session(tmp_path, "2026-02-23")
        assert result is None


# ---------------------------------------------------------------------------
# summarize_session tests
# ---------------------------------------------------------------------------


def _make_mock_db(session_title=None, title_source=None, session_exists=True):
    """Build a minimal mock database for summarize_session tests."""
    db = MagicMock()

    if session_exists:
        mock_session = MagicMock()
        mock_session.title = session_title
        mock_session.metadata = {"title_source": title_source} if title_source else {}
        db.get_session = AsyncMock(return_value=mock_session)
    else:
        db.get_session = AsyncMock(return_value=None)

    db.update_session = AsyncMock()
    return db


class TestSummarizeSession:
    @pytest.mark.asyncio
    async def test_skips_on_non_cadence_exchange(self, tmp_path):
        """Does not call the summarizer on exchanges outside the cadence."""
        db = _make_mock_db()
        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
        ) as mock_call:
            await summarize_session(
                session_id="sess_001",
                message="Hello",
                result_text="Hi there",
                tool_calls=[],
                exchange_number=2,  # not in cadence
                session_title=None,
                title_source=None,
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        mock_call.assert_not_called()
        db.update_session.assert_not_called()

    @pytest.mark.asyncio
    async def test_writes_title_and_summary_on_first_exchange(self, tmp_path):
        """Writes both title and summary when summarizer returns both."""
        db = _make_mock_db(session_title=None, title_source=None)

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("User asked about Python. Claude explained basics.", "Python Basics Chat"),
        ):
            await summarize_session(
                session_id="sess_001",
                message="What is Python?",
                result_text="Python is a programming language.",
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
        assert call_args[0][0] == "sess_001"
        update = call_args[0][1]
        assert update.title == "Python Basics Chat"
        assert update.summary == "User asked about Python. Claude explained basics."
        assert update.metadata["title_source"] == "ai"

    @pytest.mark.asyncio
    async def test_respects_user_title_source_guard(self, tmp_path):
        """Does not overwrite title when title_source == 'user'."""
        db = _make_mock_db(session_title="My Custom Title", title_source="user")

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("Summary text.", "AI Override Title"),
        ):
            await summarize_session(
                session_id="sess_002",
                message="Some question",
                result_text="Some answer",
                tool_calls=[],
                exchange_number=1,
                session_title="My Custom Title",
                title_source="user",
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        db.update_session.assert_called_once()
        update = db.update_session.call_args[0][1]
        # Title must NOT be set — user title is protected
        assert update.title is None
        # Summary should still be written
        assert update.summary == "Summary text."

    @pytest.mark.asyncio
    async def test_skips_update_when_title_unchanged(self, tmp_path):
        """Does not write title when summarizer returns the same title."""
        db = _make_mock_db(session_title="Existing Title", title_source="ai")

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("New summary.", "Existing Title"),  # same title
        ):
            await summarize_session(
                session_id="sess_003",
                message="Question",
                result_text="Answer",
                tool_calls=[],
                exchange_number=3,
                session_title="Existing Title",
                title_source="ai",
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        db.update_session.assert_called_once()
        update = db.update_session.call_args[0][1]
        assert update.title is None  # unchanged title not re-written
        assert update.summary == "New summary."

    @pytest.mark.asyncio
    async def test_writes_only_summary_when_no_title(self, tmp_path):
        """Only writes summary when summarizer returns None title."""
        db = _make_mock_db()

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("Just a summary.", None),
        ):
            await summarize_session(
                session_id="sess_004",
                message="Question",
                result_text="Answer",
                tool_calls=[],
                exchange_number=1,
                session_title="Some Title",
                title_source="ai",
                database=db,
                vault_path=tmp_path,
                claude_token=None,
            )

        db.update_session.assert_called_once()
        update = db.update_session.call_args[0][1]
        assert update.title is None
        assert update.summary == "Just a summary."

    @pytest.mark.asyncio
    async def test_skips_db_write_when_both_none(self, tmp_path):
        """Does not call update_session when summarizer returns (None, None)."""
        db = _make_mock_db()

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=(None, None),
        ):
            await summarize_session(
                session_id="sess_005",
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

        db.update_session.assert_not_called()

    @pytest.mark.asyncio
    async def test_never_raises_on_summarizer_exception(self, tmp_path):
        """summarize_session catches all exceptions and never raises."""
        db = _make_mock_db()

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            side_effect=RuntimeError("SDK exploded"),
        ):
            # Must not raise
            await summarize_session(
                session_id="sess_006",
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
        """summarize_session catches DB errors and never raises."""
        db = _make_mock_db()
        db.update_session = AsyncMock(side_effect=Exception("DB connection lost"))

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("Summary.", "New Title"),
        ):
            await summarize_session(
                session_id="sess_007",
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
    async def test_skips_title_write_when_session_not_found(self, tmp_path):
        """When get_session returns None, title is not written but summary is."""
        db = _make_mock_db(session_exists=False)

        with patch(
            "parachute.core.session_summarizer._call_summarizer",
            new_callable=AsyncMock,
            return_value=("Summary text.", "New Title"),
        ):
            await summarize_session(
                session_id="sess_008",
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

        db.update_session.assert_called_once()
        update = db.update_session.call_args[0][1]
        # Title skipped (session not found to fetch for metadata update)
        assert update.title is None
        assert update.summary == "Summary text."
