"""Tests for the composable agent tool registry."""

import pytest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

from parachute.core.agent_tools import TOOL_FACTORIES, bind_tools


class TestToolRegistry:
    """Tests for TOOL_FACTORIES registration."""

    def test_day_tools_registered(self):
        """Day-scoped tools are in the registry."""
        # Ensure imports have run
        import parachute.core.daily_agent_tools  # noqa: F401

        assert "read_days_notes" in TOOL_FACTORIES
        assert "read_days_chats" in TOOL_FACTORIES
        assert "read_recent_journals" in TOOL_FACTORIES
        assert "read_recent_sessions" in TOOL_FACTORIES
        assert "write_card" in TOOL_FACTORIES

    def test_note_tools_registered(self):
        """Note-scoped tools are in the registry."""
        import parachute.core.triggered_agent_tools  # noqa: F401

        assert "read_this_note" in TOOL_FACTORIES
        assert "update_this_note" in TOOL_FACTORIES
        assert "update_note_tags" in TOOL_FACTORIES
        assert "update_note_metadata" in TOOL_FACTORIES

    def test_legacy_aliases(self):
        """Old tool names still resolve to the same factories."""
        import parachute.core.daily_agent_tools  # noqa: F401
        import parachute.core.triggered_agent_tools  # noqa: F401

        assert TOOL_FACTORIES["read_journal"] is TOOL_FACTORIES["read_days_notes"]
        assert TOOL_FACTORIES["read_chat_log"] is TOOL_FACTORIES["read_days_chats"]
        assert TOOL_FACTORIES["read_entry"] is TOOL_FACTORIES["read_this_note"]
        assert TOOL_FACTORIES["update_entry_content"] is TOOL_FACTORIES["update_this_note"]

    def test_all_factories_have_required_keys(self):
        """Every registered factory has a frozenset of required keys."""
        import parachute.core.daily_agent_tools  # noqa: F401
        import parachute.core.triggered_agent_tools  # noqa: F401

        for name, (factory, required_keys) in TOOL_FACTORIES.items():
            assert callable(factory), f"{name} factory is not callable"
            assert isinstance(required_keys, frozenset), f"{name} required_keys is not frozenset"


class TestBindTools:
    """Tests for bind_tools() scope validation and tool creation."""

    def test_bind_day_tools_with_valid_scope(self):
        """Day-scoped tools bind successfully with date in scope."""
        graph = MagicMock()
        scope = {"date": "2026-03-22"}
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=["read_days_notes", "read_recent_journals"],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 2
        assert config is not None

    def test_bind_note_tools_with_valid_scope(self):
        """Note-scoped tools bind successfully with entry_id in scope."""
        graph = MagicMock()
        scope = {"entry_id": "abc123"}
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=["read_this_note", "update_this_note"],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 2

    def test_bind_mixed_scope_tools(self):
        """An agent can use both day and note tools if scope has both keys."""
        graph = MagicMock()
        scope = {"date": "2026-03-22", "entry_id": "abc123"}
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=["read_days_notes", "read_this_note"],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 2

    def test_bind_fails_missing_scope_key(self):
        """bind_tools raises ValueError when scope is missing required keys."""
        graph = MagicMock()
        scope = {"date": "2026-03-22"}  # No entry_id
        vault_path = Path("/tmp/test-vault")

        with pytest.raises(ValueError, match="missing"):
            bind_tools(
                tool_names=["read_this_note"],  # Needs entry_id
                scope=scope,
                graph=graph,
                agent_name="test-agent",
                vault_path=vault_path,
            )

    def test_bind_fails_unknown_tool(self):
        """bind_tools raises KeyError for unregistered tool names."""
        graph = MagicMock()
        scope = {"date": "2026-03-22"}
        vault_path = Path("/tmp/test-vault")

        with pytest.raises(KeyError, match="nonexistent_tool"):
            bind_tools(
                tool_names=["nonexistent_tool"],
                scope=scope,
                graph=graph,
                agent_name="test-agent",
                vault_path=vault_path,
            )

    def test_bind_empty_tools_list(self):
        """bind_tools with empty list returns empty tools."""
        graph = MagicMock()
        scope = {"date": "2026-03-22"}
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=[],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 0

    def test_bind_with_legacy_aliases(self):
        """Legacy tool names (read_journal, read_entry) still work."""
        graph = MagicMock()
        scope = {"date": "2026-03-22", "entry_id": "abc123"}
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=["read_journal", "read_entry"],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 2

    def test_no_scope_tools_bind_with_empty_scope(self):
        """Tools with no required scope keys bind with any scope."""
        graph = MagicMock()
        scope = {}  # Empty scope
        vault_path = Path("/tmp/test-vault")

        tools, config = bind_tools(
            tool_names=["read_recent_journals", "read_recent_sessions"],
            scope=scope,
            graph=graph,
            agent_name="test-agent",
            vault_path=vault_path,
        )

        assert len(tools) == 2
