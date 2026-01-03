"""
Unit tests for agent loader.
"""

import pytest
from pathlib import Path

from parachute.lib.agent_loader import load_agent, load_all_agents, has_permission
from parachute.models.agent import AgentType, create_vault_agent


@pytest.mark.asyncio
async def test_load_agent(test_vault: Path, sample_agent_md: str):
    """Test loading an agent from markdown."""
    # Create agent file
    agent_path = test_vault / "agents" / "test-agent.md"
    agent_path.write_text(sample_agent_md)

    agent = await load_agent("agents/test-agent.md", test_vault)

    assert agent is not None
    assert agent.name == "Test Agent"
    assert agent.description == "A test agent for automated testing"
    assert agent.type == AgentType.CHATBOT
    assert "Read" in agent.tools
    assert "Write" in agent.tools


@pytest.mark.asyncio
async def test_load_nonexistent_agent(test_vault: Path):
    """Test loading a nonexistent agent."""
    agent = await load_agent("agents/nonexistent.md", test_vault)
    assert agent is None


@pytest.mark.asyncio
async def test_load_all_agents(test_vault: Path, sample_agent_md: str):
    """Test loading all agents from vault."""
    # Create multiple agents
    for i in range(3):
        agent_path = test_vault / "agents" / f"agent-{i}.md"
        agent_path.write_text(sample_agent_md.replace("Test Agent", f"Agent {i}"))

    agents = await load_all_agents(test_vault)

    assert len(agents) == 3
    names = [a.name for a in agents]
    assert "Agent 0" in names
    assert "Agent 1" in names
    assert "Agent 2" in names


@pytest.mark.asyncio
async def test_agent_permissions(test_vault: Path, sample_agent_md: str):
    """Test agent permission parsing."""
    agent_path = test_vault / "agents" / "perms-agent.md"
    agent_path.write_text(sample_agent_md)

    agent = await load_agent("agents/perms-agent.md", test_vault)

    assert has_permission(agent, "read", "anything.md") is True
    assert has_permission(agent, "write", "Documents/file.md") is True
    assert has_permission(agent, "write", "Other/file.md") is False


def test_create_vault_agent():
    """Test creating default vault agent."""
    agent = create_vault_agent()

    assert agent.name == "vault-agent"
    assert agent.type == AgentType.CHATBOT
    assert "Read" in agent.tools
    assert "Write" in agent.tools
    assert "Bash" in agent.tools
    assert "*" in agent.permissions.read
    assert "*" in agent.permissions.write


@pytest.mark.asyncio
async def test_agent_with_system_prompt(test_vault: Path):
    """Test that system prompt is extracted from markdown body."""
    agent_md = """---
agent:
  name: Prompt Agent
  type: chatbot
---

# System Prompt

This is the system prompt content.
It can span multiple lines.
"""
    agent_path = test_vault / "agents" / "prompt-agent.md"
    agent_path.write_text(agent_md)

    agent = await load_agent("agents/prompt-agent.md", test_vault)

    assert "System Prompt" in agent.system_prompt
    assert "multiple lines" in agent.system_prompt
