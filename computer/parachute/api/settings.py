"""
Settings endpoints — personal instructions, prompt visibility, and token management.
"""

import logging
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import PARACHUTE_DIR, _load_token, get_settings, save_token

logger = logging.getLogger(__name__)

# Bridge prompts removed — observe/enrich replaced by system Message writes.
# Constants kept for API backward compat (Flutter settings screen may display them).
BRIDGE_ENRICH_PROMPT = "(Bridge enrich removed — pre-turn context injection is paused)"
BRIDGE_OBSERVE_PROMPT = "(Bridge observe removed — Message nodes are written directly by the system)"

router = APIRouter()


class InstructionsUpdate(BaseModel):
    instructions: str


@router.get("/settings/prompts")
async def get_prompts(request: Request) -> dict:
    """
    Return current bridge prompts and the user's personal vault instructions.

    vaultInstructions is the contents of ~/CLAUDE.md — this file is
    injected into every main chat session automatically.
    """
    vault_claude = Path.home() / "CLAUDE.md"
    instructions = ""
    if vault_claude.exists():
        try:
            instructions = vault_claude.read_text(encoding="utf-8").strip()
        except OSError:
            pass

    return {
        "bridgeEnrichPrompt": BRIDGE_ENRICH_PROMPT,
        "bridgeObservePrompt": BRIDGE_OBSERVE_PROMPT,
        "vaultInstructions": instructions,
        "vaultInstructionsPath": "CLAUDE.md",
    }


@router.put("/settings/instructions")
async def save_instructions(body: InstructionsUpdate, request: Request) -> dict:
    """
    Save personal instructions to ~/CLAUDE.md.

    This file is automatically injected into every main chat session.
    Passing an empty string clears it.
    """
    vault_claude = Path.home() / "CLAUDE.md"
    try:
        content = body.instructions.strip()
        if content:
            vault_claude.write_text(content + "\n", encoding="utf-8")
        elif vault_claude.exists():
            vault_claude.unlink()
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"Failed to write instructions: {e}") from e

    return {"ok": True, "path": "CLAUDE.md"}


# --- Token management ---


class TokenUpdate(BaseModel):
    token: str


@router.get("/settings/token")
async def get_token_status(request: Request) -> dict:
    """
    Return token configuration status without exposing the full token.

    Returns {"configured": bool, "prefix": "sk-ant-...abc" | null}.
    """
    token = _load_token(PARACHUTE_DIR)
    if not token:
        return {"configured": False, "prefix": None}
    # Show first 12 + last 3 chars for identification, never the full token
    if len(token) > 15:
        prefix = token[:12] + "..." + token[-3:]
    else:
        prefix = "***"
    return {"configured": True, "prefix": prefix}


@router.put("/settings/token")
async def save_token_endpoint(body: TokenUpdate, request: Request) -> dict:
    """
    Save a Claude OAuth token and hot-reload it in the running server.

    Writes to ~/.parachute/.token (0600 permissions) and updates the
    in-memory settings so new sessions pick up the token immediately.
    """
    token = body.token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="Token cannot be empty")

    save_token(PARACHUTE_DIR, token)

    # Hot-reload: update in-memory settings so next stream uses the new token
    settings = get_settings()
    settings.claude_code_oauth_token = token

    # Update sandbox's token reference if it exists
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator is not None:
        sandbox = getattr(orchestrator, "_sandbox", None)
        if sandbox is not None:
            sandbox.claude_token = token

    logger.info("Token updated via API and hot-reloaded")
    return {"ok": True, "configured": True}
