"""
Skills management API endpoints.

Skills are reusable prompt templates stored in the vault.
"""

import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request, UploadFile, File
from pydantic import BaseModel

from parachute.config import get_settings

router = APIRouter()
logger = logging.getLogger(__name__)


class CreateSkillInput(BaseModel):
    """Input for creating a new skill."""

    name: str
    description: Optional[str] = None
    content: str


def get_skills_dir() -> Path:
    """Get the skills directory."""
    settings = get_settings()
    return settings.vault_path / ".skills"


def parse_skill_file(skill_path: Path) -> Optional[dict[str, Any]]:
    """Parse a skill markdown file and extract metadata."""
    if not skill_path.exists():
        return None

    try:
        content = skill_path.read_text(encoding="utf-8")

        # Parse frontmatter if present
        name = skill_path.stem
        description = ""
        version = "1.0.0"
        allowed_tools: list[str] = []
        prompt = content

        if content.startswith("---"):
            parts = content.split("---", 2)
            if len(parts) >= 3:
                frontmatter = parts[1].strip()
                prompt = parts[2].strip()

                for line in frontmatter.split("\n"):
                    if ":" in line:
                        key, value = line.split(":", 1)
                        key = key.strip().lower().replace("-", "_")
                        value = value.strip()
                        raw_value = value.strip('"').strip("'")
                        if key == "name":
                            name = raw_value
                        elif key == "description":
                            description = raw_value
                        elif key == "version":
                            version = raw_value
                        elif key == "allowed_tools":
                            if value.startswith("[") and value.endswith("]"):
                                allowed_tools = [
                                    t.strip().strip('"').strip("'")
                                    for t in value[1:-1].split(",")
                                    if t.strip()
                                ]
                            elif raw_value:
                                allowed_tools = [raw_value]

        stat = skill_path.stat()
        skills_dir = get_skills_dir()
        is_directory = skill_path.parent != skills_dir

        # Detect source
        path_str = str(skill_path)
        if ".parachute/plugins/" in path_str:
            source = "plugin"
        elif ".skills/" in path_str:
            source = "custom"
        else:
            source = "vault"

        result: dict[str, Any] = {
            "name": name,
            "directory": skill_path.parent.name if is_directory else skill_path.stem,
            "description": description,
            "content": prompt,
            "size": stat.st_size,
            "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            "version": version,
            "allowed_tools": allowed_tools,
            "is_directory": is_directory,
            "source": source,
        }

        # For directory skills, list all files
        if is_directory:
            files = []
            for f in skill_path.parent.iterdir():
                if f.is_file():
                    fstat = f.stat()
                    files.append({"name": f.name, "size": fstat.st_size})
            files.sort(key=lambda x: x["name"])
            result["files"] = files

        return result
    except Exception as e:
        logger.error(f"Error parsing skill {skill_path}: {e}")
        return None


@router.get("/skills")
async def list_skills(request: Request) -> dict[str, Any]:
    """
    List all available skills.
    """
    skills_dir = get_skills_dir()
    skills = []

    if not skills_dir.exists():
        return {"skills": []}

    try:
        # Look for skill files/directories
        for item in skills_dir.iterdir():
            if item.is_file() and item.suffix == ".md":
                skill = parse_skill_file(item)
                if skill:
                    skills.append(skill)
            elif item.is_dir():
                # Look for skill.md or index.md in directory
                for candidate in ["skill.md", "index.md", f"{item.name}.md"]:
                    skill_file = item / candidate
                    if skill_file.exists():
                        skill = parse_skill_file(skill_file)
                        if skill:
                            skill["directory"] = item.name
                            skills.append(skill)
                        break

        # Sort by name
        skills.sort(key=lambda s: s["name"].lower())

    except Exception as e:
        logger.error(f"Error listing skills: {e}")

    return {"skills": skills}


@router.get("/skills/{name}")
async def get_skill(request: Request, name: str) -> dict[str, Any]:
    """
    Get a specific skill by name/directory.
    """
    skills_dir = get_skills_dir()

    # Try direct file first
    skill_file = skills_dir / f"{name}.md"
    if skill_file.exists():
        skill = parse_skill_file(skill_file)
        if skill:
            return skill

    # Try directory
    skill_dir = skills_dir / name
    if skill_dir.is_dir():
        for candidate in ["skill.md", "index.md", f"{name}.md"]:
            skill_file = skill_dir / candidate
            if skill_file.exists():
                skill = parse_skill_file(skill_file)
                if skill:
                    skill["directory"] = name
                    return skill

    raise HTTPException(status_code=404, detail=f"Skill '{name}' not found")


@router.post("/skills")
async def create_skill(request: Request, body: CreateSkillInput) -> dict[str, Any]:
    """
    Create a new skill.
    """
    skills_dir = get_skills_dir()
    skills_dir.mkdir(parents=True, exist_ok=True)

    # Create skill file
    skill_file = skills_dir / f"{body.name}.md"

    if skill_file.exists():
        raise HTTPException(status_code=409, detail=f"Skill '{body.name}' already exists")

    # Build content with frontmatter
    content = f"""---
name: {body.name}
description: {body.description or ''}
---

{body.content}
"""

    skill_file.write_text(content, encoding="utf-8")
    logger.info(f"Created skill: {body.name}")

    skill = parse_skill_file(skill_file)
    return {"success": True, "skill": skill}


@router.delete("/skills/{name}")
async def delete_skill(request: Request, name: str) -> dict[str, Any]:
    """
    Delete a skill.
    """
    skills_dir = get_skills_dir()

    # Try direct file first
    skill_file = skills_dir / f"{name}.md"
    if skill_file.exists():
        skill_file.unlink()
        logger.info(f"Deleted skill file: {name}")
        return {"success": True, "deleted": name}

    # Try directory
    skill_dir = skills_dir / name
    if skill_dir.is_dir():
        import shutil

        shutil.rmtree(skill_dir)
        logger.info(f"Deleted skill directory: {name}")
        return {"success": True, "deleted": name}

    raise HTTPException(status_code=404, detail=f"Skill '{name}' not found")


@router.post("/skills/upload")
async def upload_skill(request: Request, file: UploadFile = File(...)) -> dict[str, Any]:
    """
    Upload a .skill file (ZIP format).
    """
    import zipfile
    import tempfile
    import shutil

    if not file.filename:
        raise HTTPException(status_code=400, detail="No file provided")

    skills_dir = get_skills_dir()
    skills_dir.mkdir(parents=True, exist_ok=True)

    # Get skill name from filename
    skill_name = file.filename.replace(".skill", "").replace(".zip", "")

    # Check if already exists
    if (skills_dir / skill_name).exists() or (skills_dir / f"{skill_name}.md").exists():
        raise HTTPException(status_code=409, detail=f"Skill '{skill_name}' already exists")

    try:
        # Save uploaded file temporarily
        with tempfile.NamedTemporaryFile(delete=False, suffix=".zip") as tmp:
            content = await file.read()
            tmp.write(content)
            tmp_path = tmp.name

        # Extract zip
        with zipfile.ZipFile(tmp_path, "r") as zf:
            # Create skill directory
            skill_dir = skills_dir / skill_name
            skill_dir.mkdir(exist_ok=True)

            # Extract all files
            zf.extractall(skill_dir)

        # Clean up temp file
        Path(tmp_path).unlink()

        # Parse the skill
        skill = None
        for candidate in ["skill.md", "index.md", f"{skill_name}.md"]:
            skill_file = skill_dir / candidate
            if skill_file.exists():
                skill = parse_skill_file(skill_file)
                if skill:
                    skill["directory"] = skill_name
                    break

        if not skill:
            # Clean up failed upload
            shutil.rmtree(skill_dir)
            raise HTTPException(status_code=400, detail="No valid skill file found in archive")

        logger.info(f"Uploaded skill: {skill_name}")
        return {"success": True, "skill": skill}

    except zipfile.BadZipFile:
        raise HTTPException(status_code=400, detail="Invalid ZIP file")
    except Exception as e:
        logger.error(f"Error uploading skill: {e}")
        raise HTTPException(status_code=500, detail=f"Upload failed: {e}")
