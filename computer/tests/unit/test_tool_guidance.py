"""Tests for dynamic tool guidance generation."""

from parachute.core.tool_guidance import TOOL_GROUPS, build_tool_guidance


class TestToolGroups:
    """Verify the structure of the TOOL_GROUPS data."""

    def test_all_groups_have_required_keys(self):
        """Each group must have name, trust, guidance, and tools."""
        for group in TOOL_GROUPS:
            assert "name" in group, f"Missing 'name' in group: {group}"
            assert "trust" in group, f"Missing 'trust' in group: {group.get('name')}"
            assert "guidance" in group, f"Missing 'guidance' in group: {group.get('name')}"
            assert "tools" in group, f"Missing 'tools' in group: {group.get('name')}"
            assert len(group["tools"]) > 0, f"Empty tools in group: {group['name']}"

    def test_all_tools_have_name_and_description(self):
        """Each tool must have a name and description."""
        for group in TOOL_GROUPS:
            for tool in group["tools"]:
                assert "name" in tool, f"Missing 'name' in tool of group {group['name']}"
                assert "description" in tool, f"Missing 'description' for tool {tool.get('name')}"

    def test_trust_levels_are_valid(self):
        """Trust levels must be 'direct' or 'sandboxed'."""
        for group in TOOL_GROUPS:
            assert group["trust"] in ("direct", "sandboxed"), (
                f"Invalid trust level '{group['trust']}' in group {group['name']}"
            )

    def test_brain_query_and_execute_are_direct_only(self):
        """brain_query and brain_execute must be in a direct-only group."""
        direct_tools = set()
        for group in TOOL_GROUPS:
            if group["trust"] == "direct":
                for tool in group["tools"]:
                    direct_tools.add(tool["name"])
        assert "brain_query" in direct_tools
        assert "brain_execute" in direct_tools

    def test_vault_read_tools_are_sandboxed(self):
        """Vault read tools should be available in sandboxed sessions."""
        sandboxed_tools = set()
        for group in TOOL_GROUPS:
            if group["trust"] == "sandboxed":
                for tool in group["tools"]:
                    sandboxed_tools.add(tool["name"])

        expected_read_tools = {
            "search_memory",
            "search_chats",
            "list_chats",
            "get_chat",
            "get_exchange",
            "list_notes",
            "write_note",
            "brain_schema",
        }
        assert expected_read_tools.issubset(sandboxed_tools), (
            f"Missing vault read tools in sandboxed groups: "
            f"{expected_read_tools - sandboxed_tools}"
        )


class TestBuildToolGuidance:
    """Tests for the build_tool_guidance() function."""

    def test_direct_trust_includes_all_groups(self):
        """Direct trust sessions should see all tool groups."""
        result = build_tool_guidance("direct")
        assert "## Vault Tools" in result
        assert "Memory Search" in result
        assert "Browse" in result
        assert "Raw Queries" in result
        assert "Sessions & Tags" in result
        assert "Multi-Agent" in result

    def test_sandboxed_trust_excludes_direct_groups(self):
        """Sandboxed sessions should NOT see direct-only groups."""
        result = build_tool_guidance("sandboxed")
        assert "## Vault Tools" in result
        assert "Memory Search" in result
        assert "Browse" in result
        assert "Raw Queries" not in result
        assert "brain_query" not in result
        assert "brain_execute" not in result

    def test_sandboxed_includes_vault_read_tools(self):
        """Sandboxed sessions should see vault read tools."""
        result = build_tool_guidance("sandboxed")
        assert "search_memory" in result
        assert "list_chats" in result
        assert "get_chat" in result
        assert "get_exchange" in result
        assert "list_notes" in result
        assert "write_note" in result

    def test_tool_names_have_mcp_prefix(self):
        """Tool names should include the mcp__parachute__ prefix for discoverability."""
        result = build_tool_guidance("direct")
        assert "mcp__parachute__search_memory" in result
        assert "mcp__parachute__list_chats" in result

    def test_includes_guidance_text(self):
        """Output should include the contextual guidance text, not just tool names."""
        result = build_tool_guidance("sandboxed")
        # Check for guidance from the Memory Search group
        assert "Search the vault" in result
        # Check for guidance from the Browse group
        assert "Browse and read past conversations" in result

    def test_empty_string_when_no_groups_match(self, monkeypatch):
        """Should return empty string if no tool groups match the trust level."""
        monkeypatch.setattr("parachute.core.tool_guidance.TOOL_GROUPS", [])
        assert build_tool_guidance("direct") == ""
        assert build_tool_guidance("sandboxed") == ""

    def test_direct_is_superset_of_sandboxed(self):
        """Direct guidance should contain every sandboxed group plus direct-only groups."""
        direct = build_tool_guidance("direct")
        sandboxed = build_tool_guidance("sandboxed")
        # Every sandboxed tool group must appear in both outputs
        for group in TOOL_GROUPS:
            if group["trust"] == "sandboxed":
                assert group["name"] in direct
                assert group["name"] in sandboxed
        # Direct-only groups must appear only in direct output
        for group in TOOL_GROUPS:
            if group["trust"] == "direct":
                assert group["name"] in direct
                assert group["name"] not in sandboxed
