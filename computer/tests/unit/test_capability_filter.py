"""Tests for workspace capability filtering."""

from pathlib import Path

from parachute.core.capability_filter import FilteredCapabilities, filter_capabilities
from parachute.models.workspace import PluginConfig, WorkspaceCapabilities


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
        """When include_user is False, ~/.claude/plugins/ is excluded."""
        user_plugins = Path.home() / ".claude" / "plugins"
        other_dir = Path("/opt/custom-plugins")
        caps = WorkspaceCapabilities(
            plugins=PluginConfig(include_user=False),
        )

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
