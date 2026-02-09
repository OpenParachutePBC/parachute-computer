"""
Workspace configuration models.

Workspaces are named capability sets stored as YAML in the vault.
They control what MCPs, skills, agents, and plugins are available
in sessions created under them.
"""

from typing import Any, Literal, Optional, Union

from pydantic import BaseModel, Field


class PluginConfig(BaseModel):
    """Plugin configuration for a workspace."""

    include_user: bool = Field(
        default=True,
        description="Load plugins from ~/.claude/plugins/",
    )
    dirs: list[str] = Field(
        default_factory=list,
        description="Additional plugin directories",
    )


class SandboxConfig(BaseModel):
    """Docker sandbox configuration for a workspace."""

    memory: str = Field(default="512m", description="Memory limit")
    cpu: str = Field(default="1.0", description="CPU limit")
    timeout: int = Field(default=300, description="Timeout in seconds")


class WorkspaceCapabilities(BaseModel):
    """Capability sets for a workspace.

    Each capability can be:
    - "all": pass everything through (default)
    - "none": empty set
    - list[str]: only named items
    """

    mcps: Union[Literal["all", "none"], list[str]] = Field(
        default="all",
        description="MCP servers: all, none, or list of names",
    )
    skills: Union[Literal["all", "none"], list[str]] = Field(
        default="all",
        description="Skills: all, none, or list of names",
    )
    agents: Union[Literal["all", "none"], list[str]] = Field(
        default="all",
        description="Agents: all, none, or list of names",
    )
    plugins: PluginConfig = Field(
        default_factory=PluginConfig,
        description="Plugin configuration",
    )


class WorkspaceConfig(BaseModel):
    """A workspace configuration.

    Workspaces are stored at vault/.parachute/workspaces/{slug}/config.yaml
    """

    name: str = Field(description="Display name")
    slug: str = Field(description="URL-safe identifier (kebab-case)")
    description: str = Field(default="", description="Description")
    trust_level: str = Field(
        default="full",
        alias="trust_level",
        description="Trust floor: full, vault, sandboxed",
    )
    working_directory: Optional[str] = Field(
        default=None,
        alias="working_directory",
        description="Default working directory",
    )
    model: Optional[str] = Field(
        default=None,
        description="Default model: sonnet, opus, haiku, or null",
    )
    capabilities: WorkspaceCapabilities = Field(
        default_factory=WorkspaceCapabilities,
        description="Capability configuration",
    )
    sandbox: Optional[SandboxConfig] = Field(
        default=None,
        description="Docker sandbox config (only for sandboxed trust)",
    )

    model_config = {"populate_by_name": True}

    def to_api_dict(self) -> dict[str, Any]:
        """Serialize for API response."""
        return self.model_dump(by_alias=False)

    def to_yaml_dict(self) -> dict[str, Any]:
        """Serialize for YAML storage (excludes slug, which is the directory name)."""
        data = self.model_dump(by_alias=False, exclude={"slug"})
        # Remove None values for cleaner YAML
        return {k: v for k, v in data.items() if v is not None}


class WorkspaceCreate(BaseModel):
    """Request body for creating a workspace."""

    name: str = Field(description="Display name")
    description: str = Field(default="", description="Description")
    trust_level: str = Field(default="full", description="Trust floor")
    working_directory: Optional[str] = Field(default=None)
    model: Optional[str] = Field(default=None)
    capabilities: Optional[WorkspaceCapabilities] = Field(default=None)
    sandbox: Optional[SandboxConfig] = Field(default=None)

    model_config = {"populate_by_name": True}


class WorkspaceUpdate(BaseModel):
    """Request body for updating a workspace."""

    name: Optional[str] = Field(default=None)
    description: Optional[str] = Field(default=None)
    trust_level: Optional[str] = Field(default=None)
    working_directory: Optional[str] = Field(default=None)
    model: Optional[str] = Field(default=None)
    capabilities: Optional[WorkspaceCapabilities] = Field(default=None)
    sandbox: Optional[SandboxConfig] = Field(default=None)

    model_config = {"populate_by_name": True}
