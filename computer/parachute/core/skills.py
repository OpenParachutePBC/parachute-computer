"""
Skills discovery and runtime plugin generation.

This module handles:
1. Discovering skills from {vault}/.skills/
2. Generating a runtime plugin structure that Claude can load
3. The runtime plugin symlinks back to .skills/ for the actual skill files

The approach:
- Skills are stored in {vault}/.skills/ (agent-agnostic location)
- At runtime, we generate .parachute/runtime/skills-plugin/ with proper plugin structure
- Claude loads this via --plugin-dir flag
- This keeps system prompt under Parachute's control while enabling skills
"""

import json
import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


def sanitize_skill_name(name: str) -> str:
    """
    Sanitize a skill name to kebab-case for use in directories and invocation.

    Claude's Skill tool expects kebab-case names (e.g., "creative-studio").
    This converts names like "Creative Studio" or "my_skill" to "creative-studio".
    """
    # Replace underscores and spaces with hyphens
    sanitized = name.replace("_", "-").replace(" ", "-")
    # Convert to lowercase
    sanitized = sanitized.lower()
    # Remove any characters that aren't alphanumeric or hyphens
    sanitized = "".join(c for c in sanitized if c.isalnum() or c == "-")
    # Remove consecutive hyphens
    while "--" in sanitized:
        sanitized = sanitized.replace("--", "-")
    # Strip leading/trailing hyphens
    sanitized = sanitized.strip("-")
    return sanitized


@dataclass
class SkillInfo:
    """Information about a discovered skill."""
    name: str
    description: str
    path: Path
    version: str = "1.0.0"
    allowed_tools: Optional[list[str]] = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "path": str(self.path),
            "version": self.version,
            "allowed_tools": self.allowed_tools,
        }


def parse_skill_frontmatter(content: str) -> dict[str, Any]:
    """
    Parse YAML frontmatter from skill content.

    Expected format:
    ---
    name: My Skill
    description: What it does
    version: 1.0.0
    allowed-tools: [Read, Write, Bash]
    ---

    # Skill content...
    """
    metadata: dict[str, Any] = {}

    if not content.startswith("---"):
        return metadata

    parts = content.split("---", 2)
    if len(parts) < 3:
        return metadata

    frontmatter = parts[1].strip()

    for line in frontmatter.split("\n"):
        if ":" not in line:
            continue

        key, value = line.split(":", 1)
        key = key.strip().lower().replace("-", "_")
        value = value.strip()

        # Handle arrays like [Read, Write]
        if value.startswith("[") and value.endswith("]"):
            items = value[1:-1].split(",")
            value = [item.strip().strip('"').strip("'") for item in items]
        else:
            # Strip quotes
            value = value.strip('"').strip("'")

        metadata[key] = value

    return metadata


def discover_skills(vault_path: Path) -> list[SkillInfo]:
    """
    Discover all skills in the vault's .skills directory.

    Skills can be:
    - Single .md files: .skills/my-skill.md
    - Directories with SKILL.md: .skills/my-skill/SKILL.md
    - Directories with index.md: .skills/my-skill/index.md
    """
    skills_dir = vault_path / ".skills"
    skills: list[SkillInfo] = []

    if not skills_dir.exists():
        logger.debug(f"Skills directory does not exist: {skills_dir}")
        return skills

    for item in skills_dir.iterdir():
        skill = None

        if item.is_file() and item.suffix == ".md":
            # Single file skill
            skill = _parse_skill_file(item, item.stem)

        elif item.is_dir():
            # Directory-based skill - check for skill definition files
            for candidate_name in ["SKILL.md", "skill.md", "index.md", f"{item.name}.md"]:
                candidate = item / candidate_name
                if candidate.exists():
                    skill = _parse_skill_file(candidate, item.name)
                    break

        if skill:
            skills.append(skill)

    # Sort by name for consistent ordering
    skills.sort(key=lambda s: s.name.lower())

    logger.info(f"Discovered {len(skills)} skills in {skills_dir}")
    return skills


def _parse_skill_file(path: Path, default_name: str) -> Optional[SkillInfo]:
    """Parse a skill file and extract metadata."""
    try:
        content = path.read_text(encoding="utf-8")
        metadata = parse_skill_frontmatter(content)

        return SkillInfo(
            name=metadata.get("name", default_name),
            description=metadata.get("description", ""),
            path=path,
            version=metadata.get("version", "1.0.0"),
            allowed_tools=metadata.get("allowed_tools"),
        )
    except Exception as e:
        logger.error(f"Error parsing skill {path}: {e}")
        return None


def generate_runtime_plugin(vault_path: Path, skills: Optional[list[SkillInfo]] = None) -> Optional[Path]:
    """
    Generate a runtime plugin structure that Claude can load.

    Creates:
    .parachute/runtime/skills-plugin/
    ├── .claude-plugin/
    │   └── plugin.json
    └── skills/
        └── (symlink to .skills/ or copied skills)

    Returns the path to the plugin directory, or None if no skills.
    """
    if skills is None:
        skills = discover_skills(vault_path)

    if not skills:
        logger.debug("No skills to generate plugin for")
        return None

    # Create runtime plugin directory
    plugin_dir = vault_path / ".parachute" / "runtime" / "skills-plugin"
    plugin_meta_dir = plugin_dir / ".claude-plugin"
    plugin_skills_dir = plugin_dir / "skills"

    # Clean up existing runtime plugin
    if plugin_dir.exists():
        shutil.rmtree(plugin_dir)

    plugin_meta_dir.mkdir(parents=True, exist_ok=True)
    plugin_skills_dir.mkdir(parents=True, exist_ok=True)

    # Generate plugin.json manifest
    # Note: Only use valid plugin.json keys per Claude's schema
    manifest = {
        "name": "parachute-skills",
        "version": "1.0.0",
        "description": "Auto-generated plugin for Parachute vault skills",
    }

    manifest_path = plugin_meta_dir / "plugin.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    # Create skill directories/files
    # Claude expects skills in skills/{skill-name}/ with the skill file inside
    skills_source_dir = vault_path / ".skills"

    for skill in skills:
        # Use sanitized (kebab-case) name for the directory
        # Claude's Skill tool expects kebab-case names for invocation
        safe_name = sanitize_skill_name(skill.name)
        skill_target_dir = plugin_skills_dir / safe_name
        skill_target_dir.mkdir(exist_ok=True)

        # Determine source - could be file or directory
        if skill.path.parent == skills_source_dir:
            # Single file skill - copy it
            target_file = skill_target_dir / "SKILL.md"
            shutil.copy2(skill.path, target_file)
        else:
            # Directory skill - copy the whole directory contents
            source_dir = skill.path.parent
            for item in source_dir.iterdir():
                if item.is_file():
                    shutil.copy2(item, skill_target_dir / item.name)
                elif item.is_dir():
                    shutil.copytree(item, skill_target_dir / item.name)

    logger.info(f"Generated runtime plugin at {plugin_dir} with {len(skills)} skills")
    return plugin_dir


def get_skills_for_system_prompt(vault_path: Path) -> str:
    """
    Generate a system prompt section documenting available skills.

    This can be appended to the system prompt to inform the agent
    about what skills are available without relying on Claude's
    native skill discovery.
    """
    skills = discover_skills(vault_path)

    if not skills:
        return ""

    lines = [
        "## Available Skills",
        "",
        "The following skills are available. Use the /skill command or Skill tool to invoke them:",
        "",
    ]

    for skill in skills:
        lines.append(f"- **{skill.name}**: {skill.description}")

    lines.append("")

    return "\n".join(lines)


def cleanup_runtime_plugin(vault_path: Path) -> None:
    """Remove the runtime plugin directory."""
    plugin_dir = vault_path / ".parachute" / "runtime" / "skills-plugin"
    if plugin_dir.exists():
        shutil.rmtree(plugin_dir)
        logger.debug(f"Cleaned up runtime plugin at {plugin_dir}")
