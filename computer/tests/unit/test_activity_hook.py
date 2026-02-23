"""
Tests for activity_hook.py — SDK Stop hook handler.

Covers:
- update_session_summary() helper
- update_session_title() integration with summary flow
- context_hook.py context re-injection
"""

import asyncio
import json
import sys
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.models.session import SessionCreate, SessionUpdate


# ---------------------------------------------------------------------------
# update_session_summary tests
# ---------------------------------------------------------------------------


class TestUpdateSessionSummary:
    @pytest.mark.asyncio
    async def test_persists_summary_to_db(self, test_database):
        """update_session_summary writes summary to session record."""
        from parachute.hooks.activity_hook import update_session_summary

        session_data = SessionCreate(id="hook-sum-001", title="Test", module="chat")
        await test_database.create_session(session_data)

        with patch(
            "parachute.db.database.get_database",
            new=AsyncMock(return_value=test_database),
        ):
            await update_session_summary("hook-sum-001", "Discussed Python patterns.")

        session = await test_database.get_session("hook-sum-001")
        assert session is not None
        assert session.summary == "Discussed Python patterns."

    @pytest.mark.asyncio
    async def test_skips_empty_summary(self, test_database):
        """update_session_summary does nothing for empty string."""
        from parachute.hooks.activity_hook import update_session_summary

        session_data = SessionCreate(id="hook-sum-002", title="Test", module="chat")
        await test_database.create_session(session_data)

        with patch(
            "parachute.db.database.get_database",
            new=AsyncMock(return_value=test_database),
        ):
            await update_session_summary("hook-sum-002", "")

        session = await test_database.get_session("hook-sum-002")
        assert session is not None
        assert session.summary is None  # unchanged

    @pytest.mark.asyncio
    async def test_handles_db_error_gracefully(self):
        """update_session_summary does not raise on DB failure."""
        from parachute.hooks.activity_hook import update_session_summary

        failing_db = AsyncMock()
        failing_db.update_session.side_effect = RuntimeError("DB unavailable")

        with patch(
            "parachute.db.database.get_database",
            new=AsyncMock(return_value=failing_db),
        ):
            # Should not raise — errors are logged at DEBUG level
            await update_session_summary("nonexistent-id", "Some summary.")


# ---------------------------------------------------------------------------
# Session model + DB layer tests for summary field
# ---------------------------------------------------------------------------


class TestSessionSummaryField:
    @pytest.mark.asyncio
    async def test_summary_column_exists(self, test_database):
        """The sessions table has a summary column after migration."""
        async with test_database.connection.execute(
            "SELECT summary FROM sessions LIMIT 1"
        ):
            pass  # No exception → column exists

    @pytest.mark.asyncio
    async def test_summary_defaults_to_none(self, test_database):
        """Newly created sessions have summary=None."""
        session_data = SessionCreate(id="sumfield-001", title="New", module="chat")
        session = await test_database.create_session(session_data)
        assert session.summary is None

    @pytest.mark.asyncio
    async def test_update_session_summary(self, test_database):
        """db.update_session() can set and update summary."""
        session_data = SessionCreate(id="sumfield-002", title="Chat", module="chat")
        await test_database.create_session(session_data)

        await test_database.update_session(
            "sumfield-002", SessionUpdate(summary="First summary.")
        )
        session = await test_database.get_session("sumfield-002")
        assert session.summary == "First summary."

        # Overwrite with a new summary
        await test_database.update_session(
            "sumfield-002", SessionUpdate(summary="Updated summary.")
        )
        session = await test_database.get_session("sumfield-002")
        assert session.summary == "Updated summary."

    @pytest.mark.asyncio
    async def test_summary_independent_of_title(self, test_database):
        """Updating summary does not clobber title and vice versa."""
        session_data = SessionCreate(
            id="sumfield-003", title="Original title", module="chat"
        )
        await test_database.create_session(session_data)

        await test_database.update_session(
            "sumfield-003", SessionUpdate(summary="Some summary.")
        )
        session = await test_database.get_session("sumfield-003")
        assert session.title == "Original title"
        assert session.summary == "Some summary."

        await test_database.update_session(
            "sumfield-003", SessionUpdate(title="New title")
        )
        session = await test_database.get_session("sumfield-003")
        assert session.title == "New title"
        assert session.summary == "Some summary."  # unchanged


# ---------------------------------------------------------------------------
# context_hook tests
# ---------------------------------------------------------------------------


class TestContextHook:
    def test_outputs_profile_content(self, tmp_path, capsys):
        """context_hook outputs profile.md content when present."""
        from parachute.hooks.context_hook import main

        profile = tmp_path / ".parachute" / "profile.md"
        profile.parent.mkdir(parents=True)
        profile.write_text("I am a software developer.\nI prefer Python.")

        hook_input = json.dumps({"session_id": "test-123"})

        mock_settings = MagicMock()
        mock_settings.vault_path = tmp_path

        with (
            patch("sys.stdin.read", return_value=hook_input),
            patch("parachute.config.get_settings", return_value=mock_settings),
        ):
            main()

        captured = capsys.readouterr()
        assert "I am a software developer." in captured.out
        assert "Persistent Context" in captured.out

    def test_silent_when_no_profile(self, tmp_path, capsys):
        """context_hook produces no output when profile.md is missing."""
        from parachute.hooks.context_hook import main

        hook_input = json.dumps({"session_id": "test-456"})

        mock_settings = MagicMock()
        mock_settings.vault_path = tmp_path  # No .parachute/profile.md here

        with (
            patch("sys.stdin.read", return_value=hook_input),
            patch("parachute.config.get_settings", return_value=mock_settings),
        ):
            main()

        captured = capsys.readouterr()
        assert captured.out.strip() == ""

    def test_silent_when_profile_empty(self, tmp_path, capsys):
        """context_hook produces no output when profile.md is empty."""
        from parachute.hooks.context_hook import main

        profile = tmp_path / ".parachute" / "profile.md"
        profile.parent.mkdir(parents=True)
        profile.write_text("   \n  ")  # Whitespace only

        hook_input = json.dumps({"session_id": "test-789"})

        mock_settings = MagicMock()
        mock_settings.vault_path = tmp_path

        with (
            patch("sys.stdin.read", return_value=hook_input),
            patch("parachute.config.get_settings", return_value=mock_settings),
        ):
            main()

        captured = capsys.readouterr()
        assert captured.out.strip() == ""

    def test_handles_invalid_stdin(self, tmp_path, capsys):
        """context_hook exits cleanly on malformed JSON input."""
        from parachute.hooks.context_hook import main

        with patch("sys.stdin.read", return_value="not-json"):
            main()  # Should not raise

        captured = capsys.readouterr()
        assert captured.out.strip() == ""
