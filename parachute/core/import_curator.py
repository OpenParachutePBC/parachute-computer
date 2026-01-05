"""
Import Curator - Intelligent processing of Claude exports into Parachute context files.

Instead of copying Claude's memories verbatim, this curator:
1. Parses the export structure (memories.json, projects.json)
2. Creates well-organized context files following Parachute conventions
3. Merges intelligently with existing context files
4. Prepares context for ongoing maintenance by the Chat Curator
"""

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


class ImportCurator:
    """Processes Claude exports into Parachute context files."""

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.contexts_dir = vault_path / "Chat" / "contexts"
        self.contexts_dir.mkdir(parents=True, exist_ok=True)

    def process_export(self, export_path: Path) -> dict[str, Any]:
        """
        Process a Claude export directory and create context files.

        Args:
            export_path: Path to extracted Claude export directory

        Returns:
            Summary of what was created/updated
        """
        results = {
            "files_created": [],
            "files_updated": [],
            "projects_found": [],
            "errors": [],
        }

        # Load export files
        memories_path = export_path / "memories.json"
        projects_path = export_path / "projects.json"

        memories_data = None
        projects_data = None

        if memories_path.exists():
            try:
                with open(memories_path, "r", encoding="utf-8") as f:
                    memories_data = json.load(f)
                logger.info(f"Loaded memories.json")
            except Exception as e:
                results["errors"].append(f"Failed to load memories.json: {e}")

        if projects_path.exists():
            try:
                with open(projects_path, "r", encoding="utf-8") as f:
                    projects_data = json.load(f)
                logger.info(f"Loaded projects.json with {len(projects_data)} projects")
            except Exception as e:
                results["errors"].append(f"Failed to load projects.json: {e}")

        if not memories_data and not projects_data:
            results["errors"].append("No memories.json or projects.json found")
            return results

        # Build project UUID -> name mapping
        project_map = {}
        if projects_data:
            for proj in projects_data:
                uuid = proj.get("uuid", "")
                name = proj.get("name", "Unknown")
                description = proj.get("description", "")
                project_map[uuid] = {
                    "name": name,
                    "description": description,
                    "prompt_template": proj.get("prompt_template", ""),
                }
                results["projects_found"].append(name)

        # Process memories
        if memories_data and len(memories_data) > 0:
            memory = memories_data[0]  # Usually just one entry

            # Process general context
            conversations_memory = memory.get("conversations_memory", "")
            if conversations_memory:
                result = self._create_general_context(conversations_memory)
                if result["created"]:
                    results["files_created"].append(result["file"])
                elif result["updated"]:
                    results["files_updated"].append(result["file"])

            # Process project-specific memories
            project_memories = memory.get("project_memories", {})
            for uuid, memory_content in project_memories.items():
                project_info = project_map.get(uuid, {"name": f"project-{uuid[:8]}", "description": ""})
                result = self._create_project_context(
                    project_name=project_info["name"],
                    memory_content=memory_content,
                    description=project_info.get("description", ""),
                    prompt_template=project_info.get("prompt_template", ""),
                )
                if result["created"]:
                    results["files_created"].append(result["file"])
                elif result["updated"]:
                    results["files_updated"].append(result["file"])

        return results

    def _create_general_context(self, content: str) -> dict[str, Any]:
        """Create or update general-context.md from conversations_memory."""
        file_path = self.contexts_dir / "general-context.md"
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

        if file_path.exists():
            # Append to existing file
            with open(file_path, "a", encoding="utf-8") as f:
                f.write(f"\n\n<!-- Imported from Claude export on {timestamp} -->\n")
                f.write(content)
            logger.info(f"Updated general-context.md")
            return {"file": "general-context.md", "created": False, "updated": True}
        else:
            # Create new file
            header = f"""# General Context

> Imported from Claude export on {timestamp}
> This file contains general context about you that applies across all conversations.
> The Chat Curator will continue to update this file as it learns more.

---

{content}
"""
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(header)
            logger.info(f"Created general-context.md")
            return {"file": "general-context.md", "created": True, "updated": False}

    def _create_project_context(
        self,
        project_name: str,
        memory_content: str,
        description: str = "",
        prompt_template: str = "",
    ) -> dict[str, Any]:
        """Create or update a project-specific context file."""
        # Slugify the project name for filename
        slug = self._slugify(project_name)
        file_path = self.contexts_dir / f"{slug}.md"
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

        if file_path.exists():
            # Append to existing file
            with open(file_path, "a", encoding="utf-8") as f:
                f.write(f"\n\n<!-- Imported from Claude export on {timestamp} -->\n")
                f.write(memory_content)
            logger.info(f"Updated {slug}.md")
            return {"file": f"{slug}.md", "created": False, "updated": True}
        else:
            # Create new file
            parts = [f"# {project_name}"]

            if description:
                parts.append(f"\n> {description}")

            parts.append(f"\n*Imported from Claude export on {timestamp}*")
            parts.append("\n---\n")
            parts.append(memory_content)

            if prompt_template:
                parts.append("\n\n---\n")
                parts.append("## Project Instructions\n")
                parts.append(prompt_template)

            content = "\n".join(parts)

            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content)
            logger.info(f"Created {slug}.md")
            return {"file": f"{slug}.md", "created": True, "updated": False}

    def _slugify(self, text: str) -> str:
        """Convert text to a filename-safe slug."""
        # Lowercase and replace spaces with hyphens
        slug = text.lower().strip()
        # Remove special characters except hyphens
        slug = re.sub(r'[^a-z0-9\-\s]', '', slug)
        # Replace spaces with hyphens
        slug = re.sub(r'\s+', '-', slug)
        # Remove multiple consecutive hyphens
        slug = re.sub(r'-+', '-', slug)
        # Remove leading/trailing hyphens
        slug = slug.strip('-')
        return slug or "unknown"


async def run_import_curator(vault_path: Path, export_path: Path) -> dict[str, Any]:
    """
    Run the import curator on a Claude export.

    Args:
        vault_path: Path to the Parachute vault
        export_path: Path to the extracted Claude export directory

    Returns:
        Summary of what was processed
    """
    curator = ImportCurator(vault_path)
    return curator.process_export(export_path)
