"""
Agents listing API endpoints.

Returns the built-in vault-agent plus any user agents from {vault}/.claude/agents/.
The SDK discovers .claude/agents/ natively via setting_sources=["project"],
so Parachute only manages the files — the SDK handles runtime loading.
"""

import logging
import re
from pathlib import Path
from typing import Any, Optional

import yaml
from fastapi import APIRouter, HTTPException, Request, UploadFile, File
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.models.agent import create_vault_agent

router = APIRouter()
logger = logging.getLogger(__name__)

# Agent names must be safe for use as filenames
AGENT_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")


class AgentListItem(BaseModel):
    """API response model for an agent."""

    name: str
    description: Optional[str] = None
    type: str = "chatbot"
    model: Optional[str] = None
    path: Optional[str] = None
    source: str  # "builtin", "sdk"
    tools: list[str] = []


class CreateAgentInput(BaseModel):
    """Input for creating a new agent in .claude/agents/."""

    name: str
    description: Optional[str] = None
    prompt: str
    tools: list[str] = []
    model: Optional[str] = None


def _validate_agent_name(name: str) -> None:
    """Validate agent name is safe for filesystem use."""
    if not name or not AGENT_NAME_RE.match(name):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid agent name '{name}'. Use only letters, numbers, hyphens, and underscores.",
        )


def _get_sdk_agents_dir(vault_path: Path) -> Path:
    """Get the SDK-native agents directory."""
    return vault_path / ".claude" / "agents"


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


def _scan_sdk_agents(vault_path: Path) -> list[AgentListItem]:
    """Scan .claude/agents/ for user-created agent files."""
    agents_dir = _get_sdk_agents_dir(vault_path)
    if not agents_dir.exists():
        return []

    items: list[AgentListItem] = []
    for agent_file in sorted(agents_dir.glob("*.md")):
        name = agent_file.stem
        try:
            content = agent_file.read_text(encoding="utf-8")
            description = f"Agent: {name}"
            model = None
            tools: list[str] = []

            # Parse YAML frontmatter if present
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    try:
                        data = yaml.safe_load(parts[1].strip())
                        if isinstance(data, dict):
                            description = data.get("description", description)
                            model = data.get("model")
                            tools = data.get("tools", [])
                            if isinstance(tools, str):
                                tools = [t.strip() for t in tools.split(",")]
                    except yaml.YAMLError:
                        pass

            items.append(
                AgentListItem(
                    name=name,
                    description=description,
                    type="chatbot",
                    model=model,
                    path=f".claude/agents/{agent_file.name}",
                    source="sdk",
                    tools=tools,
                )
            )
        except Exception as e:
            logger.warning(f"Failed to read agent file {agent_file}: {e}")

    return items


@router.get("/agents")
async def list_agents(request: Request) -> dict[str, Any]:
    """List all available agents."""
    settings = get_settings()
    items: list[dict[str, Any]] = []

    # 1. Built-in vault-agent always first
    items.append(_vault_agent_to_item().model_dump())

    # 2. SDK-native agents from {vault}/.claude/agents/
    for agent_item in _scan_sdk_agents(settings.vault_path):
        items.append(agent_item.model_dump())

    return {"agents": items}


@router.get("/agents/{name}")
async def get_agent(request: Request, name: str) -> dict[str, Any]:
    """Get a single agent by name with full detail."""
    if name != "vault-agent":
        _validate_agent_name(name)
    settings = get_settings()

    # Check built-in
    if name == "vault-agent":
        agent = create_vault_agent()
        item = _vault_agent_to_item().model_dump()
        prompt = agent.system_prompt or ""
        item["system_prompt"] = prompt
        item["system_prompt_preview"] = prompt[:500] if prompt else None
        return item

    # Check SDK agents
    agents_dir = _get_sdk_agents_dir(settings.vault_path)
    agent_file = agents_dir / f"{name}.md"
    if agent_file.exists():
        content = agent_file.read_text(encoding="utf-8")
        description = f"Agent: {name}"
        model = None
        tools: list[str] = []
        prompt = content

        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                try:
                    data = yaml.safe_load(parts[1].strip())
                    if isinstance(data, dict):
                        description = data.get("description", description)
                        model = data.get("model")
                        tools = data.get("tools", [])
                        if isinstance(tools, str):
                            tools = [t.strip() for t in tools.split(",")]
                except yaml.YAMLError:
                    pass
                prompt = parts[2].strip()

        item = AgentListItem(
            name=name,
            description=description,
            type="chatbot",
            model=model,
            path=f".claude/agents/{name}.md",
            source="sdk",
            tools=tools,
        ).model_dump()
        item["system_prompt"] = prompt
        item["system_prompt_preview"] = prompt[:500] if prompt else None
        return item

    raise HTTPException(status_code=404, detail=f"Agent '{name}' not found")


@router.post("/agents")
async def create_agent(request: Request, body: CreateAgentInput) -> dict[str, Any]:
    """Create a new agent as a markdown file in .claude/agents/."""
    _validate_agent_name(body.name)

    settings = get_settings()
    agents_dir = _get_sdk_agents_dir(settings.vault_path)
    agents_dir.mkdir(parents=True, exist_ok=True)

    agent_file = agents_dir / f"{body.name}.md"
    if agent_file.exists():
        raise HTTPException(status_code=409, detail=f"Agent '{body.name}' already exists")

    # Build markdown with YAML frontmatter
    frontmatter_lines = [f"description: {body.description or f'Agent: {body.name}'}"]
    if body.tools:
        frontmatter_lines.append(f"tools: [{', '.join(body.tools)}]")
    if body.model:
        frontmatter_lines.append(f"model: {body.model}")

    content = f"---\n{chr(10).join(frontmatter_lines)}\n---\n\n{body.prompt}\n"

    agent_file.write_text(content, encoding="utf-8")
    logger.info(f"Created agent: {body.name} at {agent_file}")

    return AgentListItem(
        name=body.name,
        description=body.description or f"Agent: {body.name}",
        type="chatbot",
        model=body.model,
        path=f".claude/agents/{body.name}.md",
        source="sdk",
        tools=body.tools,
    ).model_dump()


@router.post("/agents/upload")
async def upload_agent(request: Request, file: UploadFile = File(...)) -> dict[str, Any]:
    """Upload a .md agent file to .claude/agents/."""
    settings = get_settings()
    agents_dir = _get_sdk_agents_dir(settings.vault_path)
    agents_dir.mkdir(parents=True, exist_ok=True)

    if not file.filename:
        raise HTTPException(status_code=400, detail="No file provided")

    if not file.filename.endswith(".md"):
        raise HTTPException(status_code=400, detail="Agent file must be .md format")

    name = file.filename.replace(".md", "")
    _validate_agent_name(name)

    agent_file = agents_dir / file.filename
    if agent_file.exists():
        raise HTTPException(status_code=409, detail=f"Agent '{name}' already exists")

    content = await file.read()
    agent_file.write_bytes(content)

    logger.info(f"Uploaded agent: {name} at {agent_file}")

    # Scan the file for display info
    for agent_item in _scan_sdk_agents(settings.vault_path):
        if agent_item.name == name:
            return agent_item.model_dump()

    # Fallback if scan didn't pick it up
    return AgentListItem(
        name=name,
        description=f"Agent: {name}",
        type="chatbot",
        path=f".claude/agents/{name}.md",
        source="sdk",
    ).model_dump()


@router.delete("/agents/{name}")
async def delete_agent(request: Request, name: str) -> dict[str, Any]:
    """Delete an agent from .claude/agents/."""
    if name == "vault-agent":
        raise HTTPException(status_code=403, detail="Cannot delete built-in vault-agent")

    _validate_agent_name(name)

    settings = get_settings()
    agents_dir = _get_sdk_agents_dir(settings.vault_path)
    agent_file = agents_dir / f"{name}.md"

    if not agent_file.exists():
        raise HTTPException(status_code=404, detail=f"Agent '{name}' not found")

    agent_file.unlink()
    logger.info(f"Deleted agent: {name}")
    return {"success": True, "deleted": name}
