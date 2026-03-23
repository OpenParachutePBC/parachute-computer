"""
Sandbox token management for MCP HTTP bridge.

Provides short-lived opaque tokens that authenticate sandbox containers
connecting to the host MCP endpoint. Each token carries session context
(trust level, agent name, allowed write tools) for server-side permission
enforcement.

Tokens are in-memory only — they live as long as the server process.
"""

import logging
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timezone


logger = logging.getLogger(__name__)


@dataclass
class SandboxTokenContext:
    """Context associated with a sandbox token."""

    session_id: str
    trust_level: str  # "sandboxed"
    agent_name: str | None = None  # For callers
    allowed_writes: list[str] = field(default_factory=list)
    allowed_tools: frozenset[str] | None = None  # None = all tools visible
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


class SandboxTokenStore:
    """In-memory store mapping opaque tokens to sandbox session context."""

    def __init__(self) -> None:
        self._tokens: dict[str, SandboxTokenContext] = {}

    def create_token(self, ctx: SandboxTokenContext) -> str:
        """Create and store a new token for the given context.

        Returns the opaque token string (Bearer value).
        """
        token = secrets.token_urlsafe(32)
        self._tokens[token] = ctx
        logger.info(
            f"Created sandbox token for session={ctx.session_id} "
            f"agent={ctx.agent_name} writes={ctx.allowed_writes}"
        )
        return token

    def validate_token(self, token: str) -> SandboxTokenContext | None:
        """Validate a token and return its context, or None if invalid."""
        return self._tokens.get(token)

    def revoke_token(self, token: str) -> None:
        """Revoke a token (cleanup after sandbox session ends)."""
        ctx = self._tokens.pop(token, None)
        if ctx:
            logger.info(
                f"Revoked sandbox token for session={ctx.session_id} "
                f"agent={ctx.agent_name}"
            )

    @property
    def active_count(self) -> int:
        """Number of active tokens."""
        return len(self._tokens)
