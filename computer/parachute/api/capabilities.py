"""
Unified capabilities summary endpoint.

Returns all agents, skills, and MCP servers in one lightweight call
for the workspace capability editor UI.
"""

import logging
from pathlib import Path
from typing import Any

import yaml
from fastapi import APIRouter, Request

from parachute.config import get_settings
from parachute.lib.mcp_loader import load_mcp_servers, _get_server_type
from parachute.models.agent import create_vault_agent

router = APIRouter()
logger = logging.getLogger(__name__)


@router.get("/capabilities")
async def get_capabilities(request: Request) -> dict[str, Any]:
    """
    Unified summary of all available capabilities.

    Returns lightweight lists of agents, skills, and MCP servers --
    just enough info for the workspace capability selector UI.
    """
    settings = get_settings()
    vault_path = Path.home()

    # Agents
    agent_items: list[dict[str, Any]] = []

    # Built-in vault-agent
    builtin = create_vault_agent()
    agent_items.append({
        "name": builtin.name,
        "description": builtin.description,
        "source": "builtin",
    })

    # SDK-native agents from .claude/agents/
    sdk_agents_dir = vault_path / ".claude" / "agents"
    if sdk_agents_dir.exists():
        for agent_file in sorted(sdk_agents_dir.glob("*.md")):
            description = f"Agent: {agent_file.stem}"
            try:
                content = agent_file.read_text(encoding="utf-8")
                if content.startswith("---"):
                    parts = content.split("---", 2)
                    if len(parts) >= 3:
                        data = yaml.safe_load(parts[1].strip())
                        if isinstance(data, dict):
                            description = data.get("description", description)
            except Exception:
                pass
            agent_items.append({
                "name": agent_file.stem,
                "description": description,
                "source": "sdk",
            })

    # Skills: SDK discovers .claude/skills/ natively; enumerate for UI display only
    skill_items: list[dict[str, Any]] = []
    sdk_skills_dir = vault_path / ".claude" / "skills"
    if sdk_skills_dir.exists():
        for skill_file in sorted(sdk_skills_dir.glob("*.md")):
            skill_items.append({
                "name": skill_file.stem,
                "description": "",
                "version": "1.0.0",
            })

    # MCP servers
    mcp_items: list[dict[str, Any]] = []
    servers = await load_mcp_servers(vault_path)
    for name, config in servers.items():
        mcp_items.append({
            "name": name,
            "type": _get_server_type(config),
            "builtin": config.get("_builtin", False),
        })

    return {
        "agents": agent_items,
        "skills": skill_items,
        "mcps": mcp_items,
    }
