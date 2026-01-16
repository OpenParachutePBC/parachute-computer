"""
Module management API endpoints.

Modules are top-level directories in the vault (Chat, Daily, Build, etc.)
"""

import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.models.requests import ModulePromptUpdate

logger = logging.getLogger(__name__)

router = APIRouter()

# Default prompt when no CLAUDE.md exists
DEFAULT_PROMPT = """# Parachute Agent

You are an AI companion in Parachute - an open, local-first tool for connected thinking.

## Your Role

You are a **thinking partner and memory extension**. Help the user:
- Think through ideas and problems
- Remember context from past conversations
- Explore topics and make connections
- Find information when they need it
"""


@router.get("/modules")
async def list_modules() -> dict[str, Any]:
    """
    List all modules and their status.
    """
    settings = get_settings()
    vault_path = settings.vault_path

    known_modules = ["Chat", "Daily", "Build"]
    modules = []

    for module_name in known_modules:
        module_path = vault_path / module_name
        if module_path.exists():
            has_prompt = (module_path / "CLAUDE.md").exists()
            has_sessions = (module_path / "sessions").exists()

            modules.append({
                "name": module_name.lower(),
                "displayName": module_name,
                "exists": True,
                "hasPrompt": has_prompt,
                "hasSessions": has_sessions,
            })

    return {"modules": modules}


@router.get("/modules/{mod}/prompt")
async def get_module_prompt(mod: str) -> dict[str, Any]:
    """
    Get system prompt for a module (e.g., Chat/CLAUDE.md).
    """
    settings = get_settings()

    # Normalize module name
    module_name = mod.capitalize()
    prompt_path = settings.vault_path / module_name / "CLAUDE.md"

    content = None
    exists = False

    if prompt_path.exists():
        content = prompt_path.read_text(encoding="utf-8")
        exists = True

    return {
        "module": mod,
        "path": f"{module_name}/CLAUDE.md",
        "exists": exists,
        "content": content,
        "defaultPrompt": DEFAULT_PROMPT,
    }


@router.put("/modules/{mod}/prompt")
async def update_module_prompt(mod: str, body: ModulePromptUpdate) -> dict[str, Any]:
    """
    Update system prompt for a module.

    Body: { content: string } or { reset: true } to use default
    """
    settings = get_settings()

    module_name = mod.capitalize()
    prompt_path = settings.vault_path / module_name / "CLAUDE.md"

    if body.reset:
        # Delete the file to use default
        if prompt_path.exists():
            prompt_path.unlink()
        return {"success": True, "reset": True}

    if body.content is not None:
        # Ensure module directory exists
        prompt_path.parent.mkdir(parents=True, exist_ok=True)
        prompt_path.write_text(body.content, encoding="utf-8")
        return {"success": True, "path": f"{module_name}/CLAUDE.md"}

    raise HTTPException(status_code=400, detail="content or reset required")


@router.get("/modules/{mod}/search")
async def search_module(
    mod: str,
    q: str = Query(..., description="Search query"),
    limit: int = Query(20, ge=1, le=100),
) -> dict[str, Any]:
    """
    Search module content.

    Query params:
    - q: Search query (required)
    - limit: Maximum results
    """
    # TODO: Implement semantic search with ModuleIndexer
    return {
        "module": mod,
        "query": q,
        "results": [],
        "message": "Search not yet implemented",
    }


@router.post("/modules/{mod}/index")
async def rebuild_module_index(
    mod: str,
    with_embeddings: bool = Query(True, description="Include embeddings"),
) -> dict[str, Any]:
    """
    Rebuild search index for a module.
    """
    # TODO: Implement with ModuleIndexer
    return {
        "success": True,
        "module": mod,
        "message": "Indexing not yet implemented",
    }


@router.get("/modules/{mod}/stats")
async def get_module_stats(mod: str) -> dict[str, Any]:
    """
    Get stats for a specific module.
    """
    settings = get_settings()

    module_name = mod.capitalize()
    module_path = settings.vault_path / module_name

    if not module_path.exists():
        raise HTTPException(status_code=404, detail=f"Module '{mod}' not found")

    # Count files
    file_count = 0
    total_size = 0
    for item in module_path.rglob("*"):
        if item.is_file():
            file_count += 1
            total_size += item.stat().st_size

    return {
        "module": mod,
        "fileCount": file_count,
        "totalSize": total_size,
        "hasPrompt": (module_path / "CLAUDE.md").exists(),
    }


# =============================================================================
# Module Curator Endpoints (Legacy + Generic Agent Support)
# =============================================================================


class CurateRequest(BaseModel):
    """Request body for module curation."""
    date: Optional[str] = None  # YYYY-MM-DD, defaults to today
    force: bool = False  # Run even if already processed


class AgentRunRequest(BaseModel):
    """Request body for running a daily agent."""
    date: Optional[str] = None  # YYYY-MM-DD, defaults to yesterday
    force: bool = False  # Run even if already processed


@router.post("/modules/{mod}/curate")
async def curate_module(mod: str, body: Optional[CurateRequest] = None) -> dict[str, Any]:
    """
    Trigger a curator run for a module.

    Currently supported modules:
    - daily: Creates a reflection based on journal entries (runs the 'curator' agent)

    Query params:
    - date: Date to process (YYYY-MM-DD), defaults to today
    - force: Run even if already processed today
    """
    settings = get_settings()
    module_name = mod.lower()

    # Parse request body
    date = None
    force = False
    if body:
        date = body.date
        force = body.force

    if module_name == "daily":
        # Use the daily curator (backward compatibility)
        from parachute.core.daily_curator import run_daily_curator

        try:
            result = await run_daily_curator(
                vault_path=settings.vault_path,
                date=date,
                force=force,
            )
            return {
                "module": module_name,
                **result,
            }
        except Exception as e:
            logger.error(f"Error running daily curator: {e}", exc_info=True)
            raise HTTPException(status_code=500, detail=f"Curator error: {str(e)}")

    else:
        raise HTTPException(
            status_code=400,
            detail=f"Module '{mod}' does not support curation. Supported: daily"
        )


# =============================================================================
# Generic Daily Agent Endpoints
# =============================================================================


@router.get("/modules/daily/agents")
async def list_daily_agents() -> dict[str, Any]:
    """
    List all configured daily agents.

    Returns information about each agent including:
    - name: Agent identifier
    - display_name: Human-readable name
    - description: What the agent does
    - schedule: When it runs (if enabled)
    - output_path: Where output is written
    """
    settings = get_settings()

    from parachute.core.daily_agent import discover_daily_agents, DailyAgentState

    agents = discover_daily_agents(settings.vault_path)
    result = []

    for config in agents:
        # Get state for this agent
        state = DailyAgentState(settings.vault_path, config.name)
        state_data = state.load()

        hour, minute = config.get_schedule_hour_minute()

        result.append({
            "name": config.name,
            "displayName": config.display_name,
            "description": config.description,
            "schedule": {
                "enabled": config.schedule_enabled,
                "time": f"{hour:02d}:{minute:02d}",
            },
            "outputPath": config.output_path,
            "state": {
                "lastRunAt": state_data.get("last_run_at"),
                "lastProcessedDate": state_data.get("last_processed_date"),
                "runCount": state_data.get("run_count", 0),
            },
        })

    return {"agents": result}


@router.get("/modules/daily/agents/{agent_name}")
async def get_daily_agent(agent_name: str) -> dict[str, Any]:
    """
    Get details about a specific daily agent.

    Returns configuration, state, and whether output exists for today.
    """
    settings = get_settings()

    from parachute.core.daily_agent import get_daily_agent_config, DailyAgentState

    config = get_daily_agent_config(settings.vault_path, agent_name)
    if not config:
        raise HTTPException(status_code=404, detail=f"Agent '{agent_name}' not found")

    # Get state
    state = DailyAgentState(settings.vault_path, agent_name)
    state_data = state.load()

    # Check if there's output for today
    today = datetime.now().strftime("%Y-%m-%d")
    output_path = config.get_output_path(today)
    output_file = settings.vault_path / output_path
    has_today_output = output_file.exists()

    hour, minute = config.get_schedule_hour_minute()

    return {
        "name": config.name,
        "displayName": config.display_name,
        "description": config.description,
        "schedule": {
            "enabled": config.schedule_enabled,
            "time": f"{hour:02d}:{minute:02d}",
        },
        "outputPath": config.output_path,
        "state": state_data,
        "hasTodayOutput": has_today_output,
        "todayOutputPath": output_path if has_today_output else None,
    }


@router.post("/modules/daily/agents/{agent_name}/run")
async def run_daily_agent(agent_name: str, body: Optional[AgentRunRequest] = None) -> dict[str, Any]:
    """
    Trigger a daily agent to run.

    Args:
        agent_name: Name of the agent (e.g., "curator", "content-scout")

    Body:
        date: Date to process (YYYY-MM-DD), defaults to yesterday
        force: Run even if already processed
    """
    settings = get_settings()

    from parachute.core.daily_agent import get_daily_agent_config

    # Verify agent exists
    config = get_daily_agent_config(settings.vault_path, agent_name)
    if not config:
        raise HTTPException(status_code=404, detail=f"Agent '{agent_name}' not found")

    # Parse request body
    date = None
    force = False
    if body:
        date = body.date
        force = body.force

    try:
        from parachute.core.scheduler import trigger_agent_now

        result = await trigger_agent_now(
            agent_name=agent_name,
            vault_path=settings.vault_path,
            date=date,
            force=force,
        )
        return {
            "agent": agent_name,
            **result,
        }
    except Exception as e:
        logger.error(f"Error running agent '{agent_name}': {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Agent error: {str(e)}")


@router.get("/modules/{mod}/curator")
async def get_module_curator_status(mod: str) -> dict[str, Any]:
    """
    Get the curator status for a module.

    Returns the current state of the module's curator, including:
    - Last run time
    - Last processed date
    - Session ID (for session continuity)
    - Run count
    """
    settings = get_settings()
    module_name = mod.lower()

    if module_name == "daily":
        from parachute.core.daily_curator import DailyCuratorState

        state = DailyCuratorState(settings.vault_path)
        state_data = state.load()

        # Check if there's a reflection for today
        today = datetime.now().strftime("%Y-%m-%d")
        reflection_path = settings.vault_path / "Daily" / "reflections" / f"{today}.md"
        has_today_reflection = reflection_path.exists()

        return {
            "module": module_name,
            "hasCurator": True,
            "state": state_data,
            "hasTodayReflection": has_today_reflection,
            "todayReflectionPath": f"Daily/reflections/{today}.md" if has_today_reflection else None,
        }

    else:
        return {
            "module": module_name,
            "hasCurator": False,
            "message": f"Module '{mod}' does not have a curator configured",
        }


@router.get("/modules/{mod}/curator/transcript")
async def get_module_curator_transcript(
    mod: str,
    limit: int = Query(50, ge=1, le=200, description="Max messages to return"),
) -> dict[str, Any]:
    """
    Get the curator's conversation transcript.

    Returns the recent messages from the curator's long-running session,
    including tool calls, responses, and the curator's reasoning.
    """
    settings = get_settings()
    module_name = mod.lower()

    if module_name != "daily":
        raise HTTPException(
            status_code=400,
            detail=f"Module '{mod}' does not have a curator transcript"
        )

    from parachute.core.daily_curator import DailyCuratorState
    import json
    from pathlib import Path
    import os

    state = DailyCuratorState(settings.vault_path)
    state_data = state.load()

    session_id = state_data.get("sdk_session_id")
    if not session_id:
        return {
            "module": module_name,
            "hasTranscript": False,
            "message": "No curator session exists yet",
        }

    # Find the transcript file
    # SDK stores transcripts in ~/.claude/projects/{escaped-cwd}/{session_id}.jsonl
    claude_projects_dir = Path.home() / ".claude" / "projects"

    # The daily curator runs from the server's current working directory
    # which is typically the base/ directory. Search for the transcript
    # by session ID across all project directories.
    transcript_path = None
    possible_paths = list(claude_projects_dir.glob(f"*/{session_id}.jsonl"))
    if possible_paths:
        transcript_path = possible_paths[0]
    else:
        return {
            "module": module_name,
            "hasTranscript": False,
            "sessionId": session_id,
            "message": f"Transcript file not found for session {session_id}",
        }

    # Parse the JSONL transcript
    messages = []
    try:
        with open(transcript_path, "r") as f:
            for line in f:
                if line.strip():
                    try:
                        entry = json.loads(line)
                        # Extract relevant info
                        msg_type = entry.get("type")
                        message = entry.get("message", {})

                        if msg_type == "user" or (message and message.get("role")):
                            parsed = {
                                "type": msg_type or message.get("role"),
                                "timestamp": entry.get("timestamp"),
                            }

                            # Extract content
                            content = message.get("content")
                            if isinstance(content, str):
                                parsed["content"] = content[:2000]  # Truncate long content
                            elif isinstance(content, list):
                                # Handle content blocks (tool_use, tool_result, text)
                                parsed["blocks"] = []
                                for block in content[:10]:  # Limit blocks
                                    block_type = block.get("type")
                                    if block_type == "text":
                                        parsed["blocks"].append({
                                            "type": "text",
                                            "text": block.get("text", "")[:1000]
                                        })
                                    elif block_type == "tool_use":
                                        parsed["blocks"].append({
                                            "type": "tool_use",
                                            "name": block.get("name"),
                                            "input": str(block.get("input", {}))[:500]
                                        })
                                    elif block_type == "tool_result":
                                        result_content = block.get("content", [])
                                        text = ""
                                        if isinstance(result_content, list) and result_content:
                                            text = result_content[0].get("text", "")[:500]
                                        parsed["blocks"].append({
                                            "type": "tool_result",
                                            "tool_use_id": block.get("tool_use_id"),
                                            "text": text
                                        })

                            if message.get("model"):
                                parsed["model"] = message.get("model")

                            messages.append(parsed)

                    except json.JSONDecodeError:
                        continue

    except Exception as e:
        logger.error(f"Error reading curator transcript: {e}")
        return {
            "module": module_name,
            "hasTranscript": False,
            "sessionId": session_id,
            "error": str(e),
        }

    # Return most recent messages
    recent_messages = messages[-limit:] if len(messages) > limit else messages

    return {
        "module": module_name,
        "hasTranscript": True,
        "sessionId": session_id,
        "transcriptPath": str(transcript_path),
        "totalMessages": len(messages),
        "messages": recent_messages,
    }
