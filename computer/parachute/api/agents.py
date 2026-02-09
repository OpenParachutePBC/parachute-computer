"""
Agents listing API endpoints.

Merges agents from two sources:
1. Vault agents: markdown files in {vault}/agents/*.md (AgentDefinition)
2. Custom agents: YAML/JSON/md files in {vault}/.parachute/agents/ (AgentConfig)

Plus the built-in vault-agent which is always first.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.core.agents import discover_agents
from parachute.lib.agent_loader import load_all_agents
from parachute.models.agent import create_vault_agent

router = APIRouter()
logger = logging.getLogger(__name__)


class AgentListItem(BaseModel):
    """API response model for an agent."""

    name: str
    description: Optional[str] = None
    type: str = "chatbot"
    model: Optional[str] = None
    path: Optional[str] = None
    source: str  # "builtin", "vault_agents", "custom_agents"
    tools: list[str] = []


def _vault_agent_to_item() -> AgentListItem:
    """Convert the built-in vault-agent to an API response item."""
    agent = create_vault_agent()
    return AgentListItem(
        name=agent.name,
        description=agent.description,
        type=agent.type.value,
        model=agent.model,
        path=None,
        source="builtin",
        tools=agent.tools,
    )


@router.get("/agents")
async def list_agents(request: Request) -> dict[str, Any]:
    """List all available agents from all sources."""
    settings = get_settings()
    items: list[dict[str, Any]] = []

    # 1. Built-in vault-agent always first
    items.append(_vault_agent_to_item().model_dump())

    # 2. Vault agents from {vault}/agents/*.md
    vault_agents = await load_all_agents(settings.vault_path)
    for agent in vault_agents:
        items.append(
            AgentListItem(
                name=agent.name,
                description=agent.description,
                type=agent.type.value,
                model=agent.model,
                path=agent.path,
                source="vault_agents",
                tools=agent.tools,
            ).model_dump()
        )

    # 3. Custom agents from {vault}/.parachute/agents/
    custom_agents = discover_agents(settings.vault_path)
    for agent in custom_agents:
        items.append(
            AgentListItem(
                name=agent.name,
                description=agent.description,
                type="chatbot",
                model=agent.model,
                path=f".parachute/agents/{agent.name}",
                source="custom_agents",
                tools=agent.tools,
            ).model_dump()
        )

    return {"agents": items}


@router.get("/agents/{name}")
async def get_agent(request: Request, name: str) -> dict[str, Any]:
    """Get a single agent by name."""
    settings = get_settings()

    # Check built-in
    if name == "vault-agent":
        item = _vault_agent_to_item().model_dump()
        vault_agent = create_vault_agent()
        # Include truncated system prompt for detail view
        prompt = vault_agent.system_prompt or ""
        item["system_prompt_preview"] = prompt[:500] if prompt else None
        return item

    # Check vault agents
    vault_agents = await load_all_agents(settings.vault_path)
    for agent in vault_agents:
        if agent.name == name:
            item = AgentListItem(
                name=agent.name,
                description=agent.description,
                type=agent.type.value,
                model=agent.model,
                path=agent.path,
                source="vault_agents",
                tools=agent.tools,
            ).model_dump()
            prompt = agent.system_prompt or ""
            item["system_prompt_preview"] = prompt[:500] if prompt else None
            return item

    # Check custom agents
    custom_agents = discover_agents(settings.vault_path)
    for agent in custom_agents:
        if agent.name == name:
            item = AgentListItem(
                name=agent.name,
                description=agent.description,
                type="chatbot",
                model=agent.model,
                path=f".parachute/agents/{agent.name}",
                source="custom_agents",
                tools=agent.tools,
            ).model_dump()
            prompt = agent.prompt or ""
            item["system_prompt_preview"] = prompt[:500] if prompt else None
            return item

    raise HTTPException(status_code=404, detail=f"Agent '{name}' not found")
