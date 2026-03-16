"""Tests for CallerDispatcher filter matching and discovery."""

import json
import pytest

from parachute.core.caller_dispatch import CallerDispatcher


class TestFilterMatching:
    """Test CallerDispatcher._matches_filter() static method."""

    def test_empty_filter_matches_everything(self):
        assert CallerDispatcher._matches_filter({}, {"entry_type": "voice"}) is True
        assert CallerDispatcher._matches_filter({}, {}) is True

    def test_entry_type_match(self):
        assert CallerDispatcher._matches_filter(
            {"entry_type": "voice"},
            {"entry_type": "voice"},
        ) is True

    def test_entry_type_mismatch(self):
        assert CallerDispatcher._matches_filter(
            {"entry_type": "voice"},
            {"entry_type": "text"},
        ) is False

    def test_entry_type_missing_from_meta(self):
        assert CallerDispatcher._matches_filter(
            {"entry_type": "voice"},
            {},
        ) is False

    def test_tags_filter_match(self):
        assert CallerDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": ["meeting", "work"]},
        ) is True

    def test_tags_filter_no_match(self):
        assert CallerDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": ["personal"]},
        ) is False

    def test_tags_filter_empty_entry_tags(self):
        assert CallerDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {"tags": []},
        ) is False

    def test_tags_filter_missing_tags(self):
        assert CallerDispatcher._matches_filter(
            {"tags": ["meeting"]},
            {},
        ) is False

    def test_tags_filter_partial_match(self):
        """At least one tag matching is sufficient."""
        assert CallerDispatcher._matches_filter(
            {"tags": ["meeting", "important"]},
            {"tags": ["meeting"]},
        ) is True

    def test_multiple_filter_keys_all_must_match(self):
        """Multiple filter keys require AND matching."""
        assert CallerDispatcher._matches_filter(
            {"entry_type": "voice", "tags": ["meeting"]},
            {"entry_type": "voice", "tags": ["meeting", "work"]},
        ) is True

    def test_multiple_filter_keys_partial_fail(self):
        assert CallerDispatcher._matches_filter(
            {"entry_type": "voice", "tags": ["meeting"]},
            {"entry_type": "text", "tags": ["meeting"]},
        ) is False

    def test_generic_key_equality(self):
        assert CallerDispatcher._matches_filter(
            {"date": "2026-03-16"},
            {"date": "2026-03-16"},
        ) is True

    def test_generic_key_mismatch(self):
        assert CallerDispatcher._matches_filter(
            {"date": "2026-03-16"},
            {"date": "2026-03-17"},
        ) is False


class TestDailyAgentConfigTriggerFields:
    """Test that DailyAgentConfig parses trigger fields from graph rows."""

    def test_from_row_with_trigger_fields(self):
        from parachute.core.daily_agent import DailyAgentConfig

        row = {
            "name": "test-caller",
            "display_name": "Test Caller",
            "description": "A test caller",
            "system_prompt": "You are a test",
            "tools": '["read_entry", "update_entry_content"]',
            "schedule_enabled": "false",
            "schedule_time": "",
            "trust_level": "direct",
            "trigger_event": "note.transcription_complete",
            "trigger_filter": '{"entry_type": "voice"}',
        }

        config = DailyAgentConfig.from_row(row)
        assert config.trigger_event == "note.transcription_complete"
        assert config.trigger_filter == {"entry_type": "voice"}
        assert config.tools == ["read_entry", "update_entry_content"]
        assert config.trust_level == "direct"
        assert config.schedule_enabled is False

    def test_from_row_without_trigger_fields(self):
        """Existing rows without trigger fields should get defaults."""
        from parachute.core.daily_agent import DailyAgentConfig

        row = {
            "name": "legacy-caller",
            "display_name": "Legacy",
            "description": "",
            "system_prompt": "",
        }

        config = DailyAgentConfig.from_row(row)
        assert config.trigger_event == ""
        assert config.trigger_filter == {}

    def test_from_row_with_invalid_trigger_filter(self):
        from parachute.core.daily_agent import DailyAgentConfig

        row = {
            "name": "bad-filter",
            "trigger_filter": "not-valid-json",
        }

        config = DailyAgentConfig.from_row(row)
        assert config.trigger_filter == {}
