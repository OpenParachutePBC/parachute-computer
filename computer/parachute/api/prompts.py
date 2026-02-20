"""
Prompt API endpoints for system prompt transparency.

Allows clients to preview what system prompt will be used
without actually sending a message.
"""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Request, Query
from pydantic import BaseModel, Field

from parachute.models.agent import create_vault_agent

router = APIRouter(prefix="/prompt")
logger = logging.getLogger(__name__)


class PromptPreviewResponse(BaseModel):
    """Response containing the full system prompt and metadata."""

    prompt: str = Field(description="The full system prompt text")
    prompt_source: str = Field(alias="promptSource", description="Source type: default, module, agent, custom")
    prompt_source_path: Optional[str] = Field(alias="promptSourcePath", default=None, description="Path to source file if applicable")
    context_files: list[str] = Field(alias="contextFiles", default_factory=list, description="List of context files loaded")
    context_tokens: int = Field(alias="contextTokens", default=0, description="Estimated tokens from context")
    context_truncated: bool = Field(alias="contextTruncated", default=False, description="Whether context was truncated")
    agent_name: Optional[str] = Field(alias="agentName", default=None, description="Active agent name")
    available_agents: list[str] = Field(alias="availableAgents", default_factory=list, description="List of available agents")
    base_prompt_tokens: int = Field(alias="basePromptTokens", default=0, description="Estimated tokens in base prompt")
    total_prompt_tokens: int = Field(alias="totalPromptTokens", default=0, description="Total estimated tokens")
    working_directory: Optional[str] = Field(alias="workingDirectory", default=None, description="Working directory for agent")
    working_directory_claude_md: Optional[str] = Field(alias="workingDirectoryClaudeMd", default=None, description="Path to working dir CLAUDE.md if found")

    model_config = {"populate_by_name": True}


def get_orchestrator(request: Request):
    """Get orchestrator from app state."""
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")
    return orchestrator


@router.get("/preview", response_model=PromptPreviewResponse)
async def preview_prompt(
    request: Request,
    working_directory: Optional[str] = Query(None, alias="workingDirectory", description="Working directory for agent"),
    agent_path: Optional[str] = Query(None, alias="agentPath", description="Path to agent definition file"),
    contexts: Optional[str] = Query(None, description="Comma-separated list of context file paths"),
    custom_prompt: Optional[str] = Query(None, alias="customPrompt", description="Custom prompt to use instead of default"),
) -> PromptPreviewResponse:
    """
    Preview the system prompt that would be used for a chat.

    This allows clients to see exactly what context and instructions
    are being provided to the AI, supporting transparency.

    Query Parameters:
        - workingDirectory: Optional working directory path
        - agentPath: Optional path to a specific agent (e.g., ".agents/helper.md")
        - contexts: Optional comma-separated context file paths
        - customPrompt: Optional custom prompt to use instead of default

    Returns:
        The full system prompt text along with metadata about its composition.
    """
    orchestrator = get_orchestrator(request)

    try:
        # Parse contexts if provided
        # Note: empty string "" means vault root, so we preserve it
        context_list = None
        if contexts:
            # Split and strip, but preserve empty strings (which mean root)
            parts = contexts.split(",")
            context_list = []
            for c in parts:
                stripped = c.strip()
                # Keep empty string (root) or non-empty paths
                if stripped or c == "":
                    context_list.append(stripped)

        # Always use the default vault-agent.
        # Custom agents are discovered by the SDK natively via .claude/agents/.
        agent = create_vault_agent()

        # Build the system prompt using orchestrator's method
        prompt, metadata = await orchestrator._build_system_prompt(
            agent=agent,
            custom_prompt=custom_prompt,
            contexts=context_list,
            working_directory=working_directory,
        )

        return PromptPreviewResponse(
            prompt=prompt,
            prompt_source=metadata["prompt_source"],
            prompt_source_path=metadata.get("prompt_source_path"),
            context_files=metadata.get("context_files", []),
            context_tokens=metadata.get("context_tokens", 0),
            context_truncated=metadata.get("context_truncated", False),
            agent_name=metadata.get("agent_name"),
            available_agents=metadata.get("available_agents", []),
            base_prompt_tokens=metadata.get("base_prompt_tokens", 0),
            total_prompt_tokens=metadata.get("total_prompt_tokens", 0),
            working_directory=working_directory,
            working_directory_claude_md=metadata.get("working_directory_claude_md"),
        )

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to preview prompt: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to preview prompt: {str(e)}")
