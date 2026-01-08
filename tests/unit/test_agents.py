"""
Comprehensive tests for the agents discovery and SDK integration system.

Tests cover:
- Agent discovery from .parachute/agents/ directory
- YAML agent parsing
- JSON agent parsing
- Markdown agent parsing (with frontmatter)
- SDK format conversion
- System prompt section generation
- Edge cases and error handling
"""

import json
import pytest
from pathlib import Path

import yaml

from parachute.core.agents import (
    AgentConfig,
    discover_agents,
    agents_to_sdk_format,
    get_agents_for_system_prompt,
)


class TestAgentConfig:
    """Tests for AgentConfig dataclass."""

    def test_to_sdk_format_full(self):
        """Test full AgentConfig serialization to SDK format."""
        agent = AgentConfig(
            name="test-agent",
            description="Test agent description",
            prompt="You are a test agent.",
            tools=["Read", "Write", "Bash"],
            model="sonnet",
        )

        sdk_format = agent.to_sdk_format()

        assert sdk_format["description"] == "Test agent description"
        assert sdk_format["prompt"] == "You are a test agent."
        assert sdk_format["tools"] == ["Read", "Write", "Bash"]
        assert sdk_format["model"] == "sonnet"

    def test_to_sdk_format_minimal(self):
        """Test minimal AgentConfig serialization."""
        agent = AgentConfig(
            name="minimal",
            description="Minimal agent",
            prompt="You are minimal.",
        )

        sdk_format = agent.to_sdk_format()

        assert "description" in sdk_format
        assert "prompt" in sdk_format
        assert "tools" not in sdk_format  # Empty list not included
        assert "model" not in sdk_format  # None not included

    def test_to_sdk_format_with_empty_tools(self):
        """Test AgentConfig with empty tools list."""
        agent = AgentConfig(
            name="no-tools",
            description="Agent without tools",
            prompt="Prompt.",
            tools=[],
        )

        sdk_format = agent.to_sdk_format()

        # Empty list should not be included
        assert "tools" not in sdk_format


class TestDiscoverAgents:
    """Tests for agent discovery from filesystem."""

    @pytest.fixture
    def agents_vault(self, tmp_path):
        """Create a vault with agents directory."""
        agents_dir = tmp_path / ".parachute" / "agents"
        agents_dir.mkdir(parents=True)
        return tmp_path

    def test_discover_yaml_agent(self, agents_vault):
        """Test discovering YAML agent definition."""
        agent_file = agents_vault / ".parachute" / "agents" / "helper.yaml"
        agent_file.write_text("""
description: Helper agent
prompt: |
  You are a helpful assistant.
  Be kind and thorough.
tools:
  - Read
  - Glob
model: sonnet
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "helper"
        assert agents[0].description == "Helper agent"
        assert "helpful assistant" in agents[0].prompt
        assert agents[0].tools == ["Read", "Glob"]
        assert agents[0].model == "sonnet"

    def test_discover_yml_agent(self, agents_vault):
        """Test discovering .yml agent definition."""
        agent_file = agents_vault / ".parachute" / "agents" / "reviewer.yml"
        agent_file.write_text("""
description: Code reviewer
prompt: Review code.
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "reviewer"

    def test_discover_json_agent(self, agents_vault):
        """Test discovering JSON agent definition."""
        agent_file = agents_vault / ".parachute" / "agents" / "analyzer.json"
        agent_file.write_text(json.dumps({
            "description": "Data analyzer",
            "prompt": "Analyze data patterns.",
            "tools": ["Read", "Grep"],
            "model": "haiku",
        }))

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "analyzer"
        assert agents[0].description == "Data analyzer"
        assert agents[0].model == "haiku"

    def test_discover_markdown_agent(self, agents_vault):
        """Test discovering Markdown agent with frontmatter."""
        agent_file = agents_vault / ".parachute" / "agents" / "writer.md"
        agent_file.write_text("""---
description: Technical writer
tools: [Read, Write, Edit]
model: opus
---

# Writer Agent

You are a skilled technical writer.

## Guidelines

- Write clearly
- Be concise
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "writer"
        assert agents[0].description == "Technical writer"
        assert "skilled technical writer" in agents[0].prompt
        assert agents[0].tools == ["Read", "Write", "Edit"]
        assert agents[0].model == "opus"

    def test_discover_markdown_without_frontmatter(self, agents_vault):
        """Test Markdown agent without frontmatter uses entire content as prompt."""
        agent_file = agents_vault / ".parachute" / "agents" / "simple.md"
        agent_file.write_text("""# Simple Agent

You are a simple agent with no frontmatter.

Just follow these instructions.
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "simple"
        assert agents[0].description == "Agent: simple"
        assert "simple agent with no frontmatter" in agents[0].prompt.lower()

    def test_discover_multiple_agents(self, agents_vault):
        """Test discovering multiple agents."""
        agents_dir = agents_vault / ".parachute" / "agents"

        (agents_dir / "alpha.yaml").write_text("""
description: Alpha agent
prompt: Alpha.
""")
        (agents_dir / "beta.json").write_text(json.dumps({
            "description": "Beta agent",
            "prompt": "Beta.",
        }))
        (agents_dir / "gamma.md").write_text("""---
description: Gamma agent
---

Gamma.
""")

        agents = discover_agents(agents_vault)

        # Should be sorted alphabetically
        assert len(agents) == 3
        names = [a.name for a in agents]
        assert names == ["alpha", "beta", "gamma"]

    def test_no_agents_directory(self, tmp_path):
        """Test behavior when .parachute/agents/ doesn't exist."""
        agents = discover_agents(tmp_path)

        assert agents == []

    def test_empty_agents_directory(self, agents_vault):
        """Test behavior when agents directory is empty."""
        agents = discover_agents(agents_vault)

        assert agents == []

    def test_ignores_other_file_types(self, agents_vault):
        """Test that non-agent files are ignored."""
        agents_dir = agents_vault / ".parachute" / "agents"
        (agents_dir / "readme.txt").write_text("Not an agent")
        (agents_dir / "config.py").write_text("# Python file")

        agents = discover_agents(agents_vault)

        assert agents == []

    def test_skips_directories(self, agents_vault):
        """Test that subdirectories are ignored."""
        (agents_vault / ".parachute" / "agents" / "subdir").mkdir()

        agents = discover_agents(agents_vault)

        assert agents == []

    def test_invalid_model_ignored(self, agents_vault):
        """Test that invalid model values are ignored."""
        agent_file = agents_vault / ".parachute" / "agents" / "bad-model.yaml"
        agent_file.write_text("""
description: Agent with bad model
prompt: Prompt.
model: gpt-4  # Invalid
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].model is None

    def test_agent_without_prompt_skipped(self, agents_vault):
        """Test that agents without prompts are skipped."""
        agent_file = agents_vault / ".parachute" / "agents" / "no-prompt.yaml"
        agent_file.write_text("""
description: No prompt agent
# Missing prompt field
""")

        agents = discover_agents(agents_vault)

        assert agents == []

    def test_tools_as_comma_string(self, agents_vault):
        """Test tools specified as comma-separated string."""
        agent_file = agents_vault / ".parachute" / "agents" / "string-tools.yaml"
        agent_file.write_text("""
description: String tools agent
prompt: Prompt.
tools: "Read, Write, Bash"
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].tools == ["Read", "Write", "Bash"]


class TestAgentsToSDKFormat:
    """Tests for converting agents to SDK format."""

    def test_single_agent_conversion(self):
        """Test converting single agent to SDK format."""
        agents = [
            AgentConfig(
                name="test",
                description="Test agent",
                prompt="Be a test.",
                tools=["Read"],
                model="sonnet",
            )
        ]

        sdk_format = agents_to_sdk_format(agents)

        assert "test" in sdk_format
        assert sdk_format["test"]["description"] == "Test agent"
        assert sdk_format["test"]["prompt"] == "Be a test."

    def test_multiple_agents_conversion(self):
        """Test converting multiple agents."""
        agents = [
            AgentConfig(name="a", description="A", prompt="A."),
            AgentConfig(name="b", description="B", prompt="B."),
        ]

        sdk_format = agents_to_sdk_format(agents)

        assert len(sdk_format) == 2
        assert "a" in sdk_format
        assert "b" in sdk_format

    def test_empty_agents_list(self):
        """Test converting empty agents list."""
        sdk_format = agents_to_sdk_format([])

        assert sdk_format == {}


class TestGetAgentsForSystemPrompt:
    """Tests for system prompt generation."""

    @pytest.fixture
    def vault_with_agents(self, tmp_path):
        """Create vault with agents for prompt testing."""
        agents_dir = tmp_path / ".parachute" / "agents"
        agents_dir.mkdir(parents=True)

        (agents_dir / "reviewer.yaml").write_text("""
description: Reviews code quality
prompt: Review code.
model: sonnet
""")
        (agents_dir / "debugger.yaml").write_text("""
description: Debugs issues
prompt: Debug.
""")

        return tmp_path

    def test_generates_agents_section(self, vault_with_agents):
        """Test generates agents section for system prompt."""
        prompt_section = get_agents_for_system_prompt(vault_with_agents)

        assert "## Custom Agents" in prompt_section
        assert "**reviewer**: Reviews code quality" in prompt_section
        assert "(uses sonnet)" in prompt_section
        assert "**debugger**: Debugs issues" in prompt_section

    def test_returns_empty_when_no_agents(self, tmp_path):
        """Test returns empty string when no agents."""
        prompt_section = get_agents_for_system_prompt(tmp_path)

        assert prompt_section == ""

    def test_model_note_only_when_specified(self, vault_with_agents):
        """Test model note appears only for agents with model specified."""
        prompt_section = get_agents_for_system_prompt(vault_with_agents)

        # Reviewer has model, debugger doesn't
        assert "reviewer" in prompt_section and "(uses sonnet)" in prompt_section
        # Debugger line shouldn't have model note
        lines = prompt_section.split("\n")
        debugger_line = next(l for l in lines if "debugger" in l)
        assert "(uses" not in debugger_line


class TestYAMLParsing:
    """Tests for YAML-specific parsing edge cases."""

    @pytest.fixture
    def agents_vault(self, tmp_path):
        """Create vault with agents directory."""
        agents_dir = tmp_path / ".parachute" / "agents"
        agents_dir.mkdir(parents=True)
        return tmp_path

    def test_multiline_prompt(self, agents_vault):
        """Test YAML multiline prompt parsing."""
        agent_file = agents_vault / ".parachute" / "agents" / "multiline.yaml"
        agent_file.write_text("""
description: Multiline agent
prompt: |
  This is a multiline prompt.

  It has multiple paragraphs.

  And preserves formatting.
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert "multiline prompt" in agents[0].prompt
        assert "multiple paragraphs" in agents[0].prompt

    def test_yaml_with_special_characters(self, agents_vault):
        """Test YAML with special characters."""
        agent_file = agents_vault / ".parachute" / "agents" / "special.yaml"
        agent_file.write_text("""
description: 'Agent with "quotes" and colons'
prompt: 'Handle special chars: $var, {braces}, and "quotes"'
""")

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert "quotes" in agents[0].description


class TestJSONParsing:
    """Tests for JSON-specific parsing edge cases."""

    @pytest.fixture
    def agents_vault(self, tmp_path):
        """Create vault with agents directory."""
        agents_dir = tmp_path / ".parachute" / "agents"
        agents_dir.mkdir(parents=True)
        return tmp_path

    def test_json_with_nested_objects(self, agents_vault):
        """Test JSON agents ignore unexpected nested structures."""
        agent_file = agents_vault / ".parachute" / "agents" / "nested.json"
        agent_file.write_text(json.dumps({
            "description": "Nested agent",
            "prompt": "Prompt.",
            "tools": ["Read"],
            "extra": {"ignored": "data"},  # Extra fields should be ignored
        }))

        agents = discover_agents(agents_vault)

        assert len(agents) == 1
        assert agents[0].name == "nested"

    def test_invalid_json_skipped(self, agents_vault):
        """Test invalid JSON files are skipped."""
        agent_file = agents_vault / ".parachute" / "agents" / "broken.json"
        agent_file.write_text("{ invalid json }")

        # Should not raise, just skip the file
        agents = discover_agents(agents_vault)

        assert agents == []


class TestIntegrationWithTestVault:
    """Integration tests using the test vault at /tmp/parachute-skills-test."""

    @pytest.fixture
    def test_vault(self):
        """Reference the pre-created test vault."""
        vault = Path("/tmp/parachute-skills-test")
        if not vault.exists():
            pytest.skip("Test vault not created")
        return vault

    def test_discovers_all_test_agents(self, test_vault):
        """Test discovering all agents in test vault."""
        agents = discover_agents(test_vault)

        # Should find: researcher, debugger, writer
        assert len(agents) == 3

        agent_names = {a.name for a in agents}
        assert "researcher" in agent_names
        assert "debugger" in agent_names
        assert "writer" in agent_names

    def test_agent_properties_parsed(self, test_vault):
        """Test that agent properties are parsed correctly."""
        agents = discover_agents(test_vault)

        researcher = next(a for a in agents if a.name == "researcher")
        assert researcher.model == "sonnet"
        assert "Read" in researcher.tools
        assert "WebSearch" in researcher.tools

        writer = next(a for a in agents if a.name == "writer")
        assert writer.model == "haiku"

    def test_sdk_format_for_test_vault(self, test_vault):
        """Test SDK format generation for test vault."""
        agents = discover_agents(test_vault)
        sdk_format = agents_to_sdk_format(agents)

        assert "researcher" in sdk_format
        assert "debugger" in sdk_format
        assert "writer" in sdk_format

        # Verify structure
        for name, agent in sdk_format.items():
            assert "description" in agent
            assert "prompt" in agent

    def test_system_prompt_includes_all_agents(self, test_vault):
        """Test system prompt generation includes all agents."""
        prompt_section = get_agents_for_system_prompt(test_vault)

        assert "researcher" in prompt_section
        assert "debugger" in prompt_section
        assert "writer" in prompt_section
        assert "(uses sonnet)" in prompt_section
        assert "(uses haiku)" in prompt_section
