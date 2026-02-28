"""
Settings endpoints — personal instructions and prompt visibility.
"""

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.core.bridge_agent import BRIDGE_ENRICH_PROMPT, BRIDGE_OBSERVE_PROMPT

router = APIRouter()


class InstructionsUpdate(BaseModel):
    instructions: str


def _get_vault_path(request: Request):
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")
    return orchestrator.vault_path


@router.get("/settings/prompts")
async def get_prompts(request: Request) -> dict:
    """
    Return current bridge prompts and the user's personal vault instructions.

    vaultInstructions is the contents of vault/CLAUDE.md — this file is
    injected into every main chat session automatically.
    """
    vault_path = _get_vault_path(request)

    vault_claude = vault_path / "CLAUDE.md"
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
    Save personal instructions to vault/CLAUDE.md.

    This file is automatically injected into every main chat session.
    Passing an empty string clears it.
    """
    vault_path = _get_vault_path(request)

    vault_claude = vault_path / "CLAUDE.md"
    try:
        content = body.instructions.strip()
        if content:
            vault_claude.write_text(content + "\n", encoding="utf-8")
        elif vault_claude.exists():
            vault_claude.unlink()
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"Failed to write instructions: {e}") from e

    return {"ok": True, "path": "CLAUDE.md"}
