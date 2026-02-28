"""
Tests for Daily MCP journal functions.

Covers:
- _is_legacy_journal(): format detection
- get_journal(): legacy and new-format parsing
- list_recent_journals(): legacy and mixed listing
- search_journals(): legacy and new-format keyword search
"""

import asyncio
import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

from parachute.mcp_server import (
    _is_legacy_journal,
    get_journal,
    list_recent_journals,
    search_journals,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

LEGACY_CONTENT = """\
Good morning. It's a new day. Typing on Obsidian right now.

Today on the docket: finish the brain module, review PRs, call Kevin about LVB.

Thinking about the Woven Web grant application. Need to send the 990 forms.
"""

NEW_FORMAT_CONTENT = """\
---
date: 2026-01-15
entries:
  abc123:
    type: voice
---

# para:daily:abc123 07:30
Had a good session with Claude on the orchestrator refactor.

# para:daily:def456 09:45
Reviewed the brain module PR. Looking good.
"""


@pytest.fixture
def journals_dir(tmp_path):
    """Create a temporary journals directory with test files."""
    d = tmp_path / "Daily" / "journals"
    d.mkdir(parents=True)

    # Legacy file
    (d / "2025-08-01.md").write_text(LEGACY_CONTENT, encoding="utf-8")

    # New-format file
    (d / "2026-01-15.md").write_text(NEW_FORMAT_CONTENT, encoding="utf-8")

    return d


# ---------------------------------------------------------------------------
# _is_legacy_journal tests
# ---------------------------------------------------------------------------


class TestIsLegacyJournal:
    def test_legacy_content_detected(self):
        assert _is_legacy_journal(LEGACY_CONTENT) is True

    def test_new_format_not_legacy(self):
        assert _is_legacy_journal(NEW_FORMAT_CONTENT) is False

    def test_empty_string_is_legacy(self):
        assert _is_legacy_journal("") is True

    def test_partial_marker_not_enough(self):
        assert _is_legacy_journal("Some text with para:daily: but no hash") is True

    def test_exact_marker_not_legacy(self):
        assert _is_legacy_journal("text\n# para:daily:abc 07:30\ncontent") is False


# ---------------------------------------------------------------------------
# get_journal tests
# ---------------------------------------------------------------------------


class TestGetJournal:
    @pytest.mark.asyncio
    async def test_legacy_file_returns_single_entry(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            result = await get_journal("2025-08-01")

        assert result is not None
        assert result["date"] == "2025-08-01"
        assert result["entry_count"] == 1
        assert len(result["entries"]) == 1

        entry = result["entries"][0]
        assert entry["id"] == "legacy-2025-08-01"
        assert entry["time"] is None
        assert entry["type"] == "legacy"
        assert "Obsidian" in entry["content"]
        assert "raw_content" in result

    @pytest.mark.asyncio
    async def test_new_format_returns_structured_entries(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            result = await get_journal("2026-01-15")

        assert result is not None
        assert result["date"] == "2026-01-15"
        assert result["entry_count"] == 2
        assert len(result["entries"]) == 2

        first = result["entries"][0]
        assert first["id"] == "abc123"
        assert first["time"] == "07:30"
        assert "type" not in first  # no legacy type on new-format entries

    @pytest.mark.asyncio
    async def test_missing_file_returns_none(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            result = await get_journal("2025-01-01")

        assert result is None


# ---------------------------------------------------------------------------
# list_recent_journals tests
# ---------------------------------------------------------------------------


class TestListRecentJournals:
    @pytest.mark.asyncio
    async def test_lists_both_formats(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await list_recent_journals(limit=20)

        assert len(results) == 2
        dates = {r["date"] for r in results}
        assert "2025-08-01" in dates
        assert "2026-01-15" in dates

    @pytest.mark.asyncio
    async def test_legacy_file_has_count_one_and_type(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await list_recent_journals(limit=20)

        legacy = next(r for r in results if r["date"] == "2025-08-01")
        assert legacy["entry_count"] == 1
        assert legacy["type"] == "legacy"

    @pytest.mark.asyncio
    async def test_new_format_has_correct_count_no_type(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await list_recent_journals(limit=20)

        new_fmt = next(r for r in results if r["date"] == "2026-01-15")
        assert new_fmt["entry_count"] == 2
        assert "type" not in new_fmt

    @pytest.mark.asyncio
    async def test_limit_respected(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await list_recent_journals(limit=1)

        # Should only return most recent (2026-01-15)
        assert len(results) == 1
        assert results[0]["date"] == "2026-01-15"

    @pytest.mark.asyncio
    async def test_empty_directory(self, tmp_path):
        empty_dir = tmp_path / "Daily" / "journals"
        empty_dir.mkdir(parents=True)
        with patch("parachute.mcp_server._vault_path", str(tmp_path)):
            results = await list_recent_journals()

        assert results == []


# ---------------------------------------------------------------------------
# search_journals tests
# ---------------------------------------------------------------------------


class TestSearchJournals:
    @pytest.mark.asyncio
    async def test_finds_match_in_legacy_file(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await search_journals("Woven Web")

        assert len(results) >= 1
        legacy_hit = next((r for r in results if r["date"] == "2025-08-01"), None)
        assert legacy_hit is not None
        assert legacy_hit["type"] == "legacy"
        assert legacy_hit["entry_header"] == "legacy:2025-08-01"
        assert "Woven Web" in legacy_hit["snippet"]

    @pytest.mark.asyncio
    async def test_finds_match_in_new_format_file(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await search_journals("orchestrator")

        assert len(results) >= 1
        hit = next((r for r in results if r["date"] == "2026-01-15"), None)
        assert hit is not None
        assert "type" not in hit  # new-format results have no type field
        assert "orchestrator" in hit["snippet"].lower()

    @pytest.mark.asyncio
    async def test_no_match_returns_empty(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await search_journals("xyzzy_no_match_here")

        assert results == []

    @pytest.mark.asyncio
    async def test_case_insensitive_search(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await search_journals("woven web")

        legacy_hit = next((r for r in results if r["date"] == "2025-08-01"), None)
        assert legacy_hit is not None

    @pytest.mark.asyncio
    async def test_snippet_has_ellipsis_when_truncated(self, journals_dir):
        with patch("parachute.mcp_server._vault_path", str(journals_dir.parent.parent)):
            results = await search_journals("grant")

        assert len(results) >= 1
        snippet = results[0]["snippet"]
        # Content before match position is > 50 chars, so snippet starts with ...
        assert snippet.startswith("...")
