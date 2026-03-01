"""Tests for workspace capability filtering and trust-level filtering."""

from pathlib import Path

from parachute.core.capability_filter import (
    FilteredCapabilities,
    filter_by_trust_level,
    filter_capabilities,
)
from parachute.models.workspace import WorkspaceCapabilities


class TestFilterCapabilities:
    """Tests for the capability filter."""

    def test_all_passes_everything(self):
        caps = WorkspaceCapabilities(mcps="all", skills="all", agents="all")
        mcps = {"parachute": {}, "context7": {}}
        agents = ["agent-a", "agent-b"]
        skills = ["skill-1", "skill-2"]
        plugins = [Path("/a"), Path("/b")]

        result = filter_capabilities(caps, mcps, skills, agents, plugins)

        assert result.mcp_servers == mcps
        assert result.agents == agents
        assert result.skills == skills
        assert result.plugin_dirs == plugins

    def test_none_returns_empty(self):
        caps = WorkspaceCapabilities(mcps="none", skills="none", agents="none")
        result = filter_capabilities(
            caps,
            all_mcps={"parachute": {}},
            all_skills=["skill-1"],
            all_agents=["agent-a"],
            plugin_dirs=[Path("/a")],
        )

        assert result.mcp_servers == {}
        assert result.agents == []
        assert result.skills == []

    def test_named_list_filters(self):
        caps = WorkspaceCapabilities(
            mcps=["parachute"],
            agents=["agent-a"],
            skills=["skill-1"],
        )
        result = filter_capabilities(
            caps,
            all_mcps={"parachute": {"cmd": "x"}, "context7": {"url": "y"}},
            all_skills=["skill-1", "skill-2"],
            all_agents=["agent-a", "agent-b"],
        )

        assert result.mcp_servers == {"parachute": {"cmd": "x"}}
        assert result.agents == ["agent-a"]
        assert result.skills == ["skill-1"]

    def test_none_values_skipped(self):
        """None inputs should be left as defaults in result."""
        caps = WorkspaceCapabilities()
        result = filter_capabilities(caps)

        assert result.mcp_servers == {}
        assert result.agents == []
        assert result.skills == []
        assert result.plugin_dirs == []

    def test_plugin_exclude_user(self):
        """When plugins is a named list, only matching slugs are included."""
        user_plugins = Path.home() / ".claude" / "plugins"
        other_dir = Path("/opt/custom-plugins")
        # Allow only "custom-plugins" by slug, excluding "plugins" (user dir)
        caps = WorkspaceCapabilities(plugins=["custom-plugins"])

        result = filter_capabilities(
            caps,
            plugin_dirs=[user_plugins, other_dir],
        )

        assert user_plugins not in result.plugin_dirs
        assert other_dir in result.plugin_dirs

    def test_plugin_include_user(self):
        """When include_user is True (default), ~/.claude/plugins/ is kept."""
        user_plugins = Path.home() / ".claude" / "plugins"
        caps = WorkspaceCapabilities()

        result = filter_capabilities(
            caps,
            plugin_dirs=[user_plugins],
        )

        assert user_plugins in result.plugin_dirs

    def test_mixed_capability_sets(self):
        """Test mix of all, none, and specific filters."""
        caps = WorkspaceCapabilities(
            mcps=["parachute"],
            skills="all",
            agents="none",
        )
        result = filter_capabilities(
            caps,
            all_mcps={"parachute": {}, "context7": {}},
            all_skills=["a", "b", "c"],
            all_agents=["agent-1", "agent-2"],
        )

        assert len(result.mcp_servers) == 1
        assert "parachute" in result.mcp_servers
        assert result.skills == ["a", "b", "c"]
        assert result.agents == []


class TestFilterByTrustLevel:
    """Tests for trust-level MCP filtering."""

    def test_full_trust_sees_all(self):
        """Full trust sessions see all MCPs regardless of annotation."""
        mcps = {
            "parachute": {"command": "x", "trust_level": "sandboxed"},
            "context7": {"url": "y", "trust_level": "vault"},
            "custom": {"command": "z"},  # No annotation → defaults to full
        }
        result = filter_by_trust_level(mcps, "full")
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
            "context7": {"url": "y", "trust_level": "vault"},
            "custom": {"command": "z"},  # No annotation → full only
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
        for trust in ("full", "vault", "sandboxed"):
            result = filter_by_trust_level(mcps, trust)
            assert "parachute" in result

    def test_no_annotation_defaults_to_direct(self):
        """MCPs without trust_level annotation default to direct (most privileged access)."""
        mcps = {"custom": {"command": "my-tool"}}

        assert "custom" in filter_by_trust_level(mcps, "direct")
        assert "custom" not in filter_by_trust_level(mcps, "sandboxed")

    def test_empty_dict_returns_empty(self):
        result = filter_by_trust_level({}, "full")
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
