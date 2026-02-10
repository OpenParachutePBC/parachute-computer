"""
Agents listing API endpoints.

Merges agents from two sources:
1. Vault agents: markdown files in {vault}/agents/*.md (AgentDefinition)
2. Custom agents: YAML/JSON/md files in {vault}/.parachute/agents/ (AgentConfig)

Plus the built-in vault-agent which is always first.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request, UploadFile, File
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.core.agents import discover_agents, _parse_markdown_agent
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


class CreateAgentInput(BaseModel):
    """Input for creating a new custom agent."""

    name: str
    description: Optional[str] = None
    prompt: str
    tools: list[str] = []
    model: Optional[str] = None


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
    """Get a single agent by name with full detail."""
    settings = get_settings()

    # Check built-in
    if name == "vault-agent":
        agent = create_vault_agent()
        item = _vault_agent_to_item().model_dump()
        prompt = agent.system_prompt or ""
        item["system_prompt"] = prompt
        item["system_prompt_preview"] = prompt[:500] if prompt else None
        item["permissions"] = agent.permissions.model_dump(by_alias=True)
        item["constraints"] = agent.constraints.model_dump(by_alias=True)
        item["mcp_servers"] = agent.mcp_servers
        item["spawns"] = agent.spawns
        return item

    # Check vault agents (AgentDefinition - has permissions/constraints)
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
            item["system_prompt"] = prompt
            item["system_prompt_preview"] = prompt[:500] if prompt else None
            item["permissions"] = agent.permissions.model_dump(by_alias=True)
            item["constraints"] = agent.constraints.model_dump(by_alias=True)
            item["mcp_servers"] = agent.mcp_servers
            item["spawns"] = agent.spawns
            return item

    # Check custom agents (AgentConfig - simpler, no permissions/constraints)
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
            item["system_prompt"] = prompt
            item["system_prompt_preview"] = prompt[:500] if prompt else None
            return item

    raise HTTPException(status_code=404, detail=f"Agent '{name}' not found")


@router.post("/agents")
async def create_agent(request: Request, body: CreateAgentInput) -> dict[str, Any]:
    """Create a new custom agent as a markdown file with YAML frontmatter."""
    settings = get_settings()
    agents_dir = settings.vault_path / ".parachute" / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)

    agent_file = agents_dir / f"{body.name}.md"
    if agent_file.exists():
        raise HTTPException(status_code=409, detail=f"Agent '{body.name}' already exists")

    # Validate model if provided
    if body.model and body.model not in ("sonnet", "opus", "haiku"):
        raise HTTPException(status_code=400, detail=f"Invalid model '{body.model}'. Must be sonnet, opus, or haiku.")

    # Build markdown with YAML frontmatter
    frontmatter_lines = [f"description: {body.description or f'Agent: {body.name}'}"]
    if body.tools:
        frontmatter_lines.append(f"tools: [{', '.join(body.tools)}]")
    if body.model:
        frontmatter_lines.append(f"model: {body.model}")

    content = f"---\n{chr(10).join(frontmatter_lines)}\n---\n\n{body.prompt}\n"

    agent_file.write_text(content, encoding="utf-8")
    logger.info(f"Created custom agent: {body.name}")

    return AgentListItem(
        name=body.name,
        description=body.description or f"Agent: {body.name}",
        type="chatbot",
        model=body.model,
        path=f".parachute/agents/{body.name}",
        source="custom_agents",
        tools=body.tools,
    ).model_dump()


@router.post("/agents/upload")
async def upload_agent(request: Request, file: UploadFile = File(...)) -> dict[str, Any]:
    """Upload a .md agent file directly."""
    settings = get_settings()
    agents_dir = settings.vault_path / ".parachute" / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)

    if not file.filename:
        raise HTTPException(status_code=400, detail="No file provided")

    if not file.filename.endswith(".md"):
        raise HTTPException(status_code=400, detail="Agent file must be .md format")

    name = file.filename.replace(".md", "")
    agent_file = agents_dir / file.filename

    if agent_file.exists():
        raise HTTPException(status_code=409, detail=f"Agent '{name}' already exists")

    content = await file.read()
    agent_file.write_bytes(content)

    # Parse to validate and return the agent info
    agent = _parse_markdown_agent(agent_file, name)
    if not agent:
        agent_file.unlink()
        raise HTTPException(status_code=400, detail="Could not parse agent file (missing prompt?)")

    logger.info(f"Uploaded custom agent: {name}")

    return AgentListItem(
        name=agent.name,
        description=agent.description,
        type="chatbot",
        model=agent.model,
        path=f".parachute/agents/{name}",
        source="custom_agents",
        tools=agent.tools,
    ).model_dump()


@router.delete("/agents/{name}")
async def delete_agent(request: Request, name: str) -> dict[str, Any]:
    """Delete a custom agent. Rejects builtin and vault agents."""
    if name == "vault-agent":
        raise HTTPException(status_code=403, detail="Cannot delete built-in vault-agent")

    settings = get_settings()

    # Check if it's a vault agent (not deletable from here)
    vault_agents = await load_all_agents(settings.vault_path)
    for agent in vault_agents:
        if agent.name == name:
            raise HTTPException(
                status_code=403,
                detail=f"Cannot delete vault agent '{name}'. Remove the file from agents/ in your vault.",
            )

    # Delete from custom agents directory
    agents_dir = settings.vault_path / ".parachute" / "agents"
    for ext in (".md", ".yaml", ".yml", ".json"):
        agent_file = agents_dir / f"{name}{ext}"
        if agent_file.exists():
            agent_file.unlink()
            logger.info(f"Deleted custom agent: {name}")
            return {"success": True, "deleted": name}

    raise HTTPException(status_code=404, detail=f"Agent '{name}' not found in custom agents")
