"""
Custom agents discovery and definition for Parachute.

This module handles loading custom agents from:
1. {vault}/.parachute/agents/ - YAML/JSON agent definitions
2. Programmatic definitions passed to the SDK

Agents are subagents that can be invoked via the Task tool with custom
descriptions, prompts, tools, and models.
"""

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import yaml

logger = logging.getLogger(__name__)


@dataclass
class AgentConfig:
    """Configuration for a custom agent/subagent."""
    name: str
    description: str
    prompt: str
    tools: list[str] = field(default_factory=list)
    model: Optional[str] = None

    def to_sdk_format(self) -> dict[str, Any]:
        """Convert to the format expected by Claude SDK's --agents flag."""
        result: dict[str, Any] = {
            "description": self.description,
            "prompt": self.prompt,
        }
        if self.tools:
            result["tools"] = self.tools
        if self.model:
            result["model"] = self.model
        return result


def discover_agents(vault_path: Path) -> list[AgentConfig]:
    """
    Discover all custom agents in the vault's .parachute/agents directory.

    Agent files can be:
    - YAML files: .parachute/agents/reviewer.yaml
    - JSON files: .parachute/agents/reviewer.json
    - Markdown with frontmatter: .parachute/agents/reviewer.md

    Expected format (YAML example):
    ```yaml
    description: Reviews code for quality and best practices
    prompt: |
      You are a code reviewer. Focus on:
      - Code quality
      - Security issues
      - Performance
    tools:
      - Read
      - Grep
      - Glob
    model: sonnet  # optional: sonnet, opus, haiku
    ```
    """
    agents_dir = vault_path / ".parachute" / "agents"
    agents: list[AgentConfig] = []

    if not agents_dir.exists():
        logger.debug(f"Agents directory does not exist: {agents_dir}")
        return agents

    for item in agents_dir.iterdir():
        if not item.is_file():
            continue

        agent = None
        name = item.stem

        try:
            if item.suffix in (".yaml", ".yml"):
                agent = _parse_yaml_agent(item, name)
            elif item.suffix == ".json":
                agent = _parse_json_agent(item, name)
            elif item.suffix == ".md":
                agent = _parse_markdown_agent(item, name)
        except Exception as e:
            logger.error(f"Error parsing agent {item}: {e}")
            continue

        if agent:
            agents.append(agent)

    # Sort by name for consistent ordering
    agents.sort(key=lambda a: a.name.lower())

    logger.info(f"Discovered {len(agents)} custom agents in {agents_dir}")
    return agents


def _parse_yaml_agent(path: Path, name: str) -> Optional[AgentConfig]:
    """Parse a YAML agent definition file."""
    content = path.read_text(encoding="utf-8")
    data = yaml.safe_load(content)
    if not isinstance(data, dict):
        return None
    return _data_to_agent(data, name)


def _parse_json_agent(path: Path, name: str) -> Optional[AgentConfig]:
    """Parse a JSON agent definition file."""
    content = path.read_text(encoding="utf-8")
    data = json.loads(content)
    if not isinstance(data, dict):
        return None
    return _data_to_agent(data, name)


def _parse_markdown_agent(path: Path, name: str) -> Optional[AgentConfig]:
    """
    Parse a Markdown agent definition with YAML frontmatter.

    Format:
    ---
    description: Reviews code
    tools: [Read, Grep]
    model: sonnet
    ---

    # Agent Prompt

    You are a code reviewer...
    """
    content = path.read_text(encoding="utf-8")

    if not content.startswith("---"):
        # No frontmatter - treat entire content as prompt
        return AgentConfig(
            name=name,
            description=f"Agent: {name}",
            prompt=content.strip(),
        )

    parts = content.split("---", 2)
    if len(parts) < 3:
        return None

    frontmatter = parts[1].strip()
    prompt = parts[2].strip()

    try:
        data = yaml.safe_load(frontmatter)
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}

    data["prompt"] = prompt
    return _data_to_agent(data, name)


def _data_to_agent(data: dict[str, Any], name: str) -> Optional[AgentConfig]:
    """Convert a dictionary to an AgentConfig."""
    description = data.get("description", f"Agent: {name}")
    prompt = data.get("prompt", "")

    if not prompt:
        logger.warning(f"Agent {name} has no prompt defined")
        return None

    tools = data.get("tools", [])
    if isinstance(tools, str):
        tools = [t.strip() for t in tools.split(",")]

    model = data.get("model")
    if model and model not in ("sonnet", "opus", "haiku"):
        logger.warning(f"Agent {name} has invalid model '{model}', ignoring")
        model = None

    return AgentConfig(
        name=name,
        description=description,
        prompt=prompt,
        tools=tools,
        model=model,
    )


def agents_to_sdk_format(agents: list[AgentConfig]) -> dict[str, dict[str, Any]]:
    """
    Convert a list of AgentConfigs to the format expected by Claude SDK.

    The SDK expects:
    {
        "agent-name": {
            "description": "...",
            "prompt": "...",
            "tools": [...],
            "model": "..."
        }
    }
    """
    return {agent.name: agent.to_sdk_format() for agent in agents}


def get_agents_for_system_prompt(vault_path: Path) -> str:
    """
    Generate a system prompt section documenting available custom agents.

    This informs the agent about what subagents can be invoked via Task tool.
    Uses XML format for clear structured parsing.
    """
    agents = discover_agents(vault_path)

    if not agents:
        return ""

    lines = [
        "<custom_agents>",
        "<description>",
        "Custom agents defined in this vault. Invoke via Task tool with the agent name as subagent_type.",
        "</description>",
        "",
        "<available_agents>",
    ]

    for agent in agents:
        lines.append(f"<agent name=\"{agent.name}\">")
        lines.append(f"  <description>{agent.description}</description>")
        if agent.model:
            lines.append(f"  <model>{agent.model}</model>")
        if agent.tools:
            lines.append(f"  <tools>{', '.join(agent.tools)}</tools>")
        lines.append("</agent>")

    lines.append("</available_agents>")
    lines.append("")
    lines.append("<invocation>")
    lines.append("To invoke a custom agent, use the Task tool:")
    lines.append("")
    lines.append("Task(")
    lines.append('  subagent_type="agent-name",')
    lines.append('  prompt="Your task description"')
    lines.append(")")
    lines.append("</invocation>")
    lines.append("</custom_agents>")

    return "\n".join(lines)
