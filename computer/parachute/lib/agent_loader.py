"""
Agent definition loader.

Agents are defined in markdown files with YAML frontmatter in the agents/ directory.
"""

import logging
from pathlib import Path
from typing import Any, Optional

import aiofiles
import frontmatter
import yaml

from parachute.models.agent import (
    AgentConstraints,
    AgentContext,
    AgentDefinition,
    AgentPermissions,
    AgentTrigger,
    AgentType,
)

logger = logging.getLogger(__name__)


def _parse_agent_frontmatter(data: dict[str, Any]) -> dict[str, Any]:
    """Parse agent frontmatter, handling nested 'agent' key if present."""
    # Support both flat and nested agent definitions
    if "agent" in data:
        return data["agent"]
    return data


async def load_agent(agent_path: str, vault_path: Path) -> Optional[AgentDefinition]:
    """
    Load an agent definition from a markdown file.

    Args:
        agent_path: Relative path to agent file (e.g., 'agents/helper.md')
        vault_path: Path to the vault

    Returns:
        AgentDefinition or None if not found/invalid
    """
    full_path = vault_path / agent_path

    if not full_path.exists():
        logger.warning(f"Agent file not found: {full_path}")
        return None

    try:
        async with aiofiles.open(full_path, "r", encoding="utf-8") as f:
            content = await f.read()

        post = frontmatter.loads(content)
        data = _parse_agent_frontmatter(dict(post.metadata))

        # Build the agent definition
        agent = AgentDefinition(
            name=data.get("name", agent_path.replace("agents/", "").replace(".md", "")),
            description=data.get("description"),
            type=AgentType(data.get("type", "chatbot")),
            model=data.get("model"),
            tools=data.get("tools", []),
            mcp_servers=data.get("mcpServers"),
            system_prompt=post.content.strip(),
            path=agent_path,
        )

        # Parse context configuration
        if "context" in data:
            ctx = data["context"]
            agent.context = AgentContext(
                include=ctx.get("include", []),
                exclude=ctx.get("exclude", []),
                knowledge_file=ctx.get("knowledgeFile") or ctx.get("knowledge_file"),
                max_tokens=ctx.get("maxTokens") or ctx.get("max_tokens", 50000),
            )

        # Parse permissions
        if "permissions" in data:
            perms = data["permissions"]
            agent.permissions = AgentPermissions(
                read=perms.get("read", ["*"]),
                write=perms.get("write", ["*"]),
                spawn=perms.get("spawn", []),
                tools=perms.get("tools", []),
                approved_mcps=perms.get("approvedMcps") or perms.get("approved_mcps", []),
            )

        # Parse constraints
        if "constraints" in data:
            cons = data["constraints"]
            agent.constraints = AgentConstraints(
                max_spawns=cons.get("maxSpawns") or cons.get("max_spawns", 3),
                timeout=cons.get("timeout", 300),
            )

        # Parse triggers
        if "triggers" in data:
            trig = data["triggers"]
            agent.triggers = AgentTrigger(
                on_create=trig.get("onCreate") or trig.get("on_create"),
                on_modify=trig.get("onModify") or trig.get("on_modify"),
                schedule=trig.get("schedule"),
            )

        # Parse spawns
        agent.spawns = data.get("spawns", [])

        logger.debug(f"Loaded agent: {agent.name} from {agent_path}")
        return agent

    except yaml.YAMLError as e:
        logger.error(f"Invalid YAML in agent file {full_path}: {e}")
        return None
    except Exception as e:
        logger.error(f"Error loading agent {full_path}: {e}")
        return None


async def load_all_agents(vault_path: Path) -> list[AgentDefinition]:
    """Load all agent definitions from the vault."""
    agents_dir = vault_path / "agents"

    if not agents_dir.exists():
        return []

    agents = []
    for agent_file in agents_dir.glob("*.md"):
        relative_path = f"agents/{agent_file.name}"
        agent = await load_agent(relative_path, vault_path)
        if agent:
            agents.append(agent)

    logger.debug(f"Loaded {len(agents)} agents from {agents_dir}")
    return agents


def build_system_prompt(
    agent: AgentDefinition, context: Optional[dict[str, Any]] = None
) -> str:
    """
    Build the system prompt for an agent.

    Combines the agent's system_prompt with any context-specific additions.
    """
    prompt = agent.system_prompt or ""

    if context:
        # Add document path context for doc agents
        if "documentPath" in context:
            prompt += f"\n\nTarget document: {context['documentPath']}"

        # Add document content context
        if "documentContent" in context:
            prompt += f"\n\nDocument content:\n{context['documentContent']}"

    return prompt


def has_permission(agent: AgentDefinition, permission_type: str, path: str) -> bool:
    """
    Check if an agent has permission for a given operation.

    Args:
        agent: The agent definition
        permission_type: 'read', 'write', or 'spawn'
        path: The path to check

    Returns:
        True if permission is granted
    """
    from parachute.lib.vault_utils import matches_patterns

    patterns = getattr(agent.permissions, permission_type, [])
    return matches_patterns(path, patterns)
