"""Tests for AgentDispatcher filter matching and discovery."""

import json
import pytest

from parachute.core.agent_dispatch import AgentDispatcher


class TestFilterMatching:
    """Test AgentDispatcher._matches_filter() static method."""

    def test_empty_filter_matches_everything(self):
        assert AgentDispatcher._matches_filter({}, {"entry_type": "voice"}) is True
        assert AgentDispatcher._matches_filter({}, {}) is True

    def test_entry_type_match(self):
        assert AgentDispatcher._matches_filter(
            {"entry_type": "voice"},
            {"entry_type": "voice"},
        ) is True

    def test_entry_type_mismatch(self):
        assert AgentDispatcher._matches_filter(
            {"entry_type": "voice"},
            {"entry_type": "text"},
        ) is False

    def test_entry_type_missing_from_meta(self):
        assert AgentDispatcher._matches_filter(
            {"entry_type": "voice"},
            {},
        ) is False

    def test_tags_filter_match(self):
        assert AgentDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": ["meeting", "work"]},
        ) is True

    def test_tags_filter_no_match(self):
        assert AgentDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": ["personal"]},
        ) is False

    def test_tags_filter_empty_entry_tags(self):
        assert AgentDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": []},
        ) is False

    def test_tags_filter_missing_tags(self):
        assert AgentDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {},
        ) is False

    def test_tags_filter_partial_match(self):
        """At least one tag matching is sufficient."""
        assert AgentDispatcher._matches_filter(
            {"tags": ["meeting", "important"]},
            {"tags": ["meeting"]},
        ) is True

    def test_multiple_filter_keys_all_must_match(self):
        """Multiple filter keys require AND matching."""
        assert AgentDispatcher._matches_filter(
            {"entry_type": "voice", "tags": ["meeting"]},
            {"entry_type": "voice", "tags": ["meeting", "work"]},
        ) is True

    def test_multiple_filter_keys_partial_fail(self):
        assert AgentDispatcher._matches_filter(
            {"entry_type": "voice", "tags": ["meeting"]},
            {"entry_type": "text", "tags": ["meeting"]},
        ) is False

    def test_generic_key_equality(self):
        assert AgentDispatcher._matches_filter(
            {"date": "2026-03-16"},
            {"date": "2026-03-16"},
        ) is True

    def test_generic_key_mismatch(self):
        assert AgentDispatcher._matches_filter(
            {"date": "2026-03-16"},
            {"date": "2026-03-17"},
        ) is False


class TestDailyAgentConfigTriggerFields:
    """Test that DailyAgentConfig parses trigger fields from Tool + Trigger rows."""

    def test_from_tool_row_with_event_trigger(self):
        from parachute.core.daily_agent import DailyAgentConfig

        tool_row = {
            "name": "test-agent",
            "display_name": "Test Agent",
            "description": "A test agent",
            "system_prompt": "You are a test",
            "trust_level": "direct",
        }
        trigger_row = {
            "type": "event",
            "event": "note.transcription_complete",
            "event_filter": '{"entry_type": "voice"}',
        }

        config = DailyAgentConfig.from_tool_row(
            tool_row, can_call_names=["read-entry", "update-entry-content"],
            trigger_row=trigger_row,
        )
        assert config.trigger_event == "note.transcription_complete"
        assert config.trigger_filter == {"entry_type": "voice"}
        assert config.tools == ["read_entry", "update_entry_content"]
        assert config.trust_level == "direct"
        assert config.schedule_enabled is False

    def test_from_tool_row_without_trigger(self):
        """Tool rows without a trigger should get defaults."""
        from parachute.core.daily_agent import DailyAgentConfig

        tool_row = {
            "name": "legacy-agent",
            "display_name": "Legacy",
            "description": "",
            "system_prompt": "",
        }

        config = DailyAgentConfig.from_tool_row(tool_row, can_call_names=[])
        assert config.trigger_event == ""
        assert config.trigger_filter == {}

    def test_from_tool_row_with_invalid_trigger_filter(self):
        from parachute.core.daily_agent import DailyAgentConfig

        tool_row = {"name": "bad-filter"}
        trigger_row = {
            "type": "event",
            "event": "note.created",
            "event_filter": "not-valid-json",
        }

        config = DailyAgentConfig.from_tool_row(
            tool_row, can_call_names=[], trigger_row=trigger_row,
        )
        assert config.trigger_filter == {}
