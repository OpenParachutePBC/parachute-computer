"""Tests for trust-level capability filtering."""

from parachute.core.capability_filter import (
    FilteredCapabilities,
    filter_by_trust_level,
)


class TestFilterByTrustLevel:
    """Tests for trust-level MCP filtering."""

    def test_direct_trust_sees_all(self):
        """Direct trust sessions see all MCPs regardless of annotation."""
        mcps = {
            "parachute": {"command": "x", "trust_level": "sandboxed"},
            "context7": {"url": "y", "trust_level": "direct"},
            "custom": {"command": "z"},  # No annotation → defaults to direct
        }
        result = filter_by_trust_level(mcps, "direct")
        assert set(result.keys()) == {"parachute", "context7", "custom"}

    def test_sandboxed_trust_excludes_direct_only(self):
        """Sandboxed sessions only see MCPs annotated as sandboxed."""
        mcps = {
            "parachute": {"command": "x", "trust_level": "sandboxed"},
            "context7": {"url": "y", "trust_level": "direct"},
            "custom": {"command": "z"},  # No annotation → direct only
        }
        result = filter_by_trust_level(mcps, "sandboxed")
        assert set(result.keys()) == {"parachute"}
        assert "context7" not in result
        assert "custom" not in result

    def test_sandboxed_trust_only_sees_sandboxed(self):
        """Sandboxed trust only sees MCPs annotated as sandboxed."""
        mcps = {
            "parachute": {"command": "x", "trust_level": "sandboxed"},
            "context7": {"url": "y", "trust_level": "direct"},
            "custom": {"command": "z"},  # No annotation → direct only
        }
        result = filter_by_trust_level(mcps, "sandboxed")
        assert set(result.keys()) == {"parachute"}

    def test_builtin_parachute_always_available(self):
        """Built-in Parachute MCP has trust_level=sandboxed so it's always available."""
        mcps = {
            "parachute": {
                "command": "python",
                "trust_level": "sandboxed",
                "_builtin": True,
            },
        }
        for trust in ("direct", "sandboxed"):
            result = filter_by_trust_level(mcps, trust)
            assert "parachute" in result

    def test_no_annotation_defaults_to_direct(self):
        """MCPs without trust_level annotation default to direct (most privileged access)."""
        mcps = {"custom": {"command": "my-tool"}}

        assert "custom" in filter_by_trust_level(mcps, "direct")
        assert "custom" not in filter_by_trust_level(mcps, "sandboxed")

    def test_empty_dict_returns_empty(self):
        result = filter_by_trust_level({}, "direct")
        assert result == {}

    def test_unknown_trust_level_treated_as_direct(self):
        """Unknown trust levels in MCP configs are treated as direct (most restrictive access)."""
        mcps = {"weird": {"command": "x", "trust_level": "unknown"}}
        # Unknown MCP trust_level falls back to "direct" (order 0)
        assert "weird" in filter_by_trust_level(mcps, "direct")
        assert "weird" not in filter_by_trust_level(mcps, "sandboxed")

    def test_trust_filter_preserves_config(self):
        """Filtered MCPs retain their full config dicts."""
        mcps = {
            "parachute": {
                "command": "python",
                "args": ["-m", "server"],
                "trust_level": "sandboxed",
                "_builtin": True,
            }
        }
        result = filter_by_trust_level(mcps, "sandboxed")
        assert result["parachute"]["command"] == "python"
        assert result["parachute"]["_builtin"] is True


class TestFilteredCapabilities:
    """Tests for FilteredCapabilities dataclass."""

    def test_default_empty(self):
        """FilteredCapabilities defaults to empty collections."""
        fc = FilteredCapabilities()
        assert fc.mcp_servers == {}
        assert fc.plugin_dirs == []
        assert fc.agents == []
        assert fc.skills == []
