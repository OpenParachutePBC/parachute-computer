"""
Workspace configuration models.

Workspaces are named capability sets stored as YAML in the vault.
They control what MCPs, skills, agents, and plugins are available
in sessions created under them.
"""

from typing import Any, Literal, Optional, Union

from pydantic import BaseModel, Field, field_validator

from parachute.core.trust import TrustLevelStr


class PluginConfig(BaseModel):
    """Plugin configuration for a workspace.

    DEPRECATED: Use the 'plugins' field on WorkspaceCapabilities instead.
    Kept for backwards compatibility with existing workspace configs.
    """

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
    - list[str]: only named items (plugin slugs, MCP names, etc.)
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
    plugins: Union[Literal["all", "none"], list[str]] = Field(
        default="all",
        description="Plugins: all, none, or list of plugin slugs",
    )

    @field_validator("plugins", mode="before")
    @classmethod
    def _migrate_plugin_config(cls, v: Any) -> Any:
        """Migrate old PluginConfig format to string-based format."""
        if isinstance(v, dict):
            # Old format: {"include_user": true, "dirs": [...]}
            # Convert: include_user=true → "all", include_user=false → "none"
            if "include_user" in v or "dirs" in v:
                return "all" if v.get("include_user", True) else "none"
        return v


class WorkspaceConfig(BaseModel):
    """A workspace configuration.

    Workspaces are stored at vault/.parachute/workspaces/{slug}/config.yaml
    """

    name: str = Field(description="Display name")
    slug: str = Field(description="URL-safe identifier (kebab-case)")
    description: str = Field(default="", description="Description")
    default_trust_level: TrustLevelStr = Field(
        default="direct",
        description="Default trust level for new sessions in this workspace",
    )
    working_directory: Optional[str] = Field(
        default=None,
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

    @field_validator("default_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: Any) -> Any:
        if isinstance(v, str):
            from parachute.core.trust import normalize_trust_level
            try:
                return normalize_trust_level(v)
            except ValueError:
                return v
        return v

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
    default_trust_level: TrustLevelStr = Field(default="direct", description="Default trust level")
    working_directory: Optional[str] = Field(default=None)
    model: Optional[str] = Field(default=None)
    capabilities: Optional[WorkspaceCapabilities] = Field(default=None)
    sandbox: Optional[SandboxConfig] = Field(default=None)

    @field_validator("default_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: Any) -> Any:
        if isinstance(v, str):
            from parachute.core.trust import normalize_trust_level
            try:
                return normalize_trust_level(v)
            except ValueError:
                return v
        return v


class WorkspaceUpdate(BaseModel):
    """Request body for updating a workspace."""

    name: Optional[str] = Field(default=None)
    description: Optional[str] = Field(default=None)
    default_trust_level: Optional[TrustLevelStr] = Field(default=None, description="Default trust level")
    working_directory: Optional[str] = Field(default=None)
    model: Optional[str] = Field(default=None)
    capabilities: Optional[WorkspaceCapabilities] = Field(default=None)
    sandbox: Optional[SandboxConfig] = Field(default=None)

    @field_validator("default_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: Any) -> Any:
        if v is None or not isinstance(v, str):
            return v
        from parachute.core.trust import normalize_trust_level
        try:
            return normalize_trust_level(v)
        except ValueError:
            return v
