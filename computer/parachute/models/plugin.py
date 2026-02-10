"""
Plugin models.

Plugins follow the Claude Code plugin format:
  {slug}/.claude-plugin/plugin.json  — manifest
  {slug}/skills/                     — skill files (SKILL.md)
  {slug}/agents/                     — agent definitions
  {slug}/commands/                   — slash commands
  {slug}/.mcp.json                   — MCP server configs
"""

from typing import Any, Optional

from pydantic import BaseModel, Field


class PluginManifest(BaseModel):
    """Contents of .claude-plugin/plugin.json."""

    name: str = ""
    version: str = "0.0.0"
    description: str = ""
    author: Optional[str] = None


class InstalledPlugin(BaseModel):
    """An installed plugin with indexed contents."""

    slug: str  # Directory name
    name: str  # From plugin.json
    version: str = "0.0.0"
    description: str = ""
    author: Optional[str] = None
    source: str = "parachute"  # "parachute" | "user"
    source_url: Optional[str] = None  # GitHub URL if installed from remote
    path: str  # Absolute path on disk
    skills: list[str] = Field(default_factory=list)
    agents: list[str] = Field(default_factory=list)
    mcps: dict[str, Any] = Field(default_factory=dict)
    installed_at: Optional[str] = None  # ISO timestamp
