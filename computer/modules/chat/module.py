"""
Chat module - Streaming chat with Claude Agent SDK.

Wraps the existing orchestrator, session manager, and chat API.
The core chat routes (/api/chat, /api/sessions) are registered globally
by the server. This module provides supplementary chat-related routes
and ensures proper integration with the module system.
"""

import logging
import os
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

logger = logging.getLogger(__name__)


class ChatModule:
    """Chat module wrapping the orchestrator and session management."""

    name = "chat"
    provides = []

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self._ensure_claude_dir()
        self._brain = None

    def _ensure_claude_dir(self):
        """Ensure vault/.claude/ directory exists for SDK session storage."""
        claude_dir = self.vault_path / ".claude"
        claude_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Chat module: SDK sessions stored in {claude_dir}")

    def _get_brain(self):
        """Lazily get BrainInterface from registry."""
        if self._brain is None:
            try:
                from parachute.core.interfaces import get_registry
                self._brain = get_registry().get("BrainInterface")
            except Exception:
                pass
        return self._brain

    def get_status(self) -> dict:
        """Get chat module status for /api/modules listing."""
        brain = self._get_brain()
        return {
            "module": "chat",
            "brain_available": brain is not None,
            "sdk_session_dir": str(self.vault_path / ".claude"),
        }

    async def search_brain_context(self, query: str) -> list[dict]:
        """Search Brain entities for chat context enrichment."""
        brain = self._get_brain()
        if not brain:
            return []
        return await brain.search(query)

    def get_router(self) -> Optional[APIRouter]:
        """Return None - core chat routes are already registered globally.

        Chat streaming, session CRUD, permissions, etc. are handled by
        the main API router via api/chat.py and api/sessions.py.
        This module exists for module system integration and provides
        Brain context search as a Python API for the orchestrator.
        """
        return None
