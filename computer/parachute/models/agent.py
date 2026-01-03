"""
Agent definition models.

Agents are defined in markdown files with YAML frontmatter.
"""

from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class AgentType(str, Enum):
    """Type of agent execution."""

    CHATBOT = "chatbot"  # Interactive with persistent session
    DOC = "doc"  # Processes specific document
    STANDALONE = "standalone"  # One-shot execution


class AgentPermissions(BaseModel):
    """Permission configuration for an agent."""

    read: list[str] = Field(default_factory=lambda: ["*"])
    write: list[str] = Field(default_factory=lambda: ["*"])
    spawn: list[str] = Field(default_factory=list)
    tools: list[str] = Field(default_factory=list)
    approved_mcps: list[str] = Field(
        alias="approvedMcps",
        default_factory=list,
        description="Pre-approved MCP servers",
    )

    model_config = {"populate_by_name": True}


class AgentContext(BaseModel):
    """Context configuration for an agent."""

    include: list[str] = Field(default_factory=list)
    exclude: list[str] = Field(default_factory=list)
    knowledge_file: Optional[str] = Field(alias="knowledgeFile", default=None)
    max_tokens: int = Field(alias="maxTokens", default=50000)

    model_config = {"populate_by_name": True}


class AgentConstraints(BaseModel):
    """Execution constraints for an agent."""

    max_spawns: int = Field(alias="maxSpawns", default=3)
    timeout: int = Field(default=300, description="Timeout in seconds")

    model_config = {"populate_by_name": True}


class AgentTrigger(BaseModel):
    """Trigger configuration for doc agents."""

    on_create: Optional[str] = Field(alias="onCreate", default=None)
    on_modify: Optional[str] = Field(alias="onModify", default=None)
    schedule: Optional[str] = None

    model_config = {"populate_by_name": True}


class AgentDefinition(BaseModel):
    """Complete agent definition."""

    name: str
    description: Optional[str] = None
    type: AgentType = AgentType.CHATBOT
    model: Optional[str] = None
    tools: list[str] = Field(default_factory=list)
    mcp_servers: Optional[str | list[str]] = Field(
        alias="mcpServers",
        default=None,
        description="MCP servers: 'all', list of names, or None",
    )
    context: Optional[AgentContext] = None
    permissions: AgentPermissions = Field(default_factory=AgentPermissions)
    constraints: AgentConstraints = Field(default_factory=AgentConstraints)
    triggers: Optional[AgentTrigger] = None
    spawns: list[str] = Field(default_factory=list)
    system_prompt: str = Field(
        alias="systemPrompt",
        default="",
        description="System prompt from markdown body",
    )
    path: Optional[str] = Field(default=None, description="Path to agent file")

    model_config = {"populate_by_name": True}


# Default tools for vault agent
DEFAULT_VAULT_TOOLS = [
    "Read",
    "Write",
    "Edit",
    "MultiEdit",
    "Glob",
    "Grep",
    "LS",
    "Bash",
    "Task",
    "NotebookRead",
    "NotebookEdit",
    "WebSearch",
    "WebFetch",
    "Skill",
]


def create_vault_agent() -> AgentDefinition:
    """Create the default vault agent."""
    return AgentDefinition(
        name="vault-agent",
        description="General vault assistant",
        type=AgentType.CHATBOT,
        model=None,  # Use account default
        tools=DEFAULT_VAULT_TOOLS,
        mcp_servers="all",
        context=AgentContext(
            include=["Chat/contexts/general-context.md"],
            max_tokens=10000,
        ),
        permissions=AgentPermissions(
            read=["*"],
            write=["*"],
            spawn=["agents/*"],
            tools=DEFAULT_VAULT_TOOLS,
            approved_mcps=["*"],
        ),
        constraints=AgentConstraints(
            max_spawns=3,
            timeout=300,
        ),
        system_prompt="",
    )
