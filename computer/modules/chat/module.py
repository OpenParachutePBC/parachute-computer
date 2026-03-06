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

    async def on_load(self) -> None:
        """Register Chat schema tables in the shared graph."""
        from parachute.core.interfaces import get_registry
        graph = get_registry().get("GraphDB")
        if graph is None:
            logger.warning("Chat: GraphDB not in registry, schema registration skipped")
            return
        await graph.ensure_node_table(
            "Exchange",
            {
                "exchange_id": "STRING",
                "session_id": "STRING",
                "exchange_number": "STRING",
                "description": "STRING",
                "user_message": "STRING",
                "ai_response": "STRING",
                "context": "STRING",
                "session_title": "STRING",
                "tools_used": "STRING",
                "created_at": "STRING",
            },
            primary_key="exchange_id",
        )
        await graph.ensure_rel_table("HAS_EXCHANGE", "Chat", "Exchange")
        logger.info("Chat: graph schema registered (Exchange, HAS_EXCHANGE)")

    def _ensure_claude_dir(self):
        """Ensure vault/.claude/ directory exists for SDK session storage."""
        claude_dir = self.vault_path / ".claude"
        claude_dir.mkdir(parents=True, exist_ok=True)
        logger.info(f"Chat module: SDK sessions stored in {claude_dir}")

    def get_status(self) -> dict:
        """Get chat module status for /api/modules listing."""
        return {
            "module": "chat",
            "sdk_session_dir": str(self.vault_path / ".claude"),
        }

    def get_router(self) -> Optional[APIRouter]:
        """Return None - core chat routes are already registered globally.

        Chat streaming, session CRUD, permissions, etc. are handled by
        the main API router via api/chat.py and api/sessions.py.
        This module exists for module system integration (manifest,
        schema registration, status).
        """
        return None
