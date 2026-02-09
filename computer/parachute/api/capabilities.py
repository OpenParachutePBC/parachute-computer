"""
Unified capabilities summary endpoint.

Returns all agents, skills, and MCP servers in one lightweight call
for the workspace capability editor UI.
"""

import logging
from typing import Any

from fastapi import APIRouter, Request

from parachute.config import get_settings
from parachute.core.agents import discover_agents
from parachute.core.skills import discover_skills
from parachute.lib.agent_loader import load_all_agents
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
    vault_path = settings.vault_path

    # Agents
    agent_items: list[dict[str, Any]] = []

    # Built-in vault-agent
    builtin = create_vault_agent()
    agent_items.append({
        "name": builtin.name,
        "description": builtin.description,
        "source": "builtin",
    })

    # Vault agents
    for agent in await load_all_agents(vault_path):
        agent_items.append({
            "name": agent.name,
            "description": agent.description,
            "source": "vault_agents",
        })

    # Custom agents
    for agent in discover_agents(vault_path):
        agent_items.append({
            "name": agent.name,
            "description": agent.description,
            "source": "custom_agents",
        })

    # Skills
    skill_items: list[dict[str, Any]] = []
    for skill in discover_skills(vault_path):
        skill_items.append({
            "name": skill.name,
            "description": skill.description,
            "version": skill.version,
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
