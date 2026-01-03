"""
Permission handler for tool access control.

Implements TIER-based permission checking:
- TIER 1 (always allow): Read-only tools
- TIER 2 (configurable): Write tools - check against allowed paths
- TIER 3 (ask first): MCP tools - require user approval
"""

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Optional
from uuid import uuid4

from parachute.models.agent import AgentDefinition
from parachute.lib.vault_utils import matches_patterns

logger = logging.getLogger(__name__)


# Tool tier definitions
TIER1_ALWAYS_ALLOW = [
    "Read", "Glob", "Grep", "LS",
    "WebSearch", "WebFetch",
    "NotebookRead",
    "Task",
]

TIER2_WRITE_TOOLS = [
    "Write", "Edit", "MultiEdit",
    "Bash",
    "NotebookEdit",
]


@dataclass
class PermissionRequest:
    """A pending permission request."""

    id: str
    tool_name: str
    input_data: dict[str, Any]
    agent_name: str
    timestamp: datetime = field(default_factory=datetime.utcnow)
    status: str = "pending"  # pending, granted, denied, timeout

    # For write tools
    file_path: Optional[str] = None
    allowed_patterns: list[str] = field(default_factory=list)

    # For MCP tools
    mcp_server: Optional[str] = None
    mcp_tool: Optional[str] = None

    # Resolution
    _resolve: Optional[Callable[[str], None]] = field(default=None, repr=False)


@dataclass
class PermissionDecision:
    """Result of a permission check."""

    behavior: str  # "allow" or "deny"
    message: Optional[str] = None
    updated_input: Optional[dict[str, Any]] = None
    interrupt: bool = False


class PermissionHandler:
    """
    Handles permission checks for tool usage.

    Creates a callback that can be passed to the Claude SDK.
    """

    def __init__(
        self,
        agent: AgentDefinition,
        session_id: str,
        vault_path: str,
        on_denial: Optional[Callable[[dict[str, Any]], None]] = None,
        on_request: Optional[Callable[[PermissionRequest], None]] = None,
    ):
        """
        Initialize permission handler.

        Args:
            agent: Agent definition with permissions
            session_id: Current session ID
            vault_path: Path to vault root
            on_denial: Callback when permission is denied
            on_request: Callback when permission needs user approval
        """
        self.agent = agent
        self.session_id = session_id
        self.vault_path = vault_path
        self.on_denial = on_denial
        self.on_request = on_request

        # Pending permission requests
        self.pending: dict[str, PermissionRequest] = {}

        # Session-approved MCP servers
        self.approved_mcps: set[str] = set()

        # Limits
        self.max_pending = 100
        self.timeout_seconds = 120

    def create_sdk_callback(self):
        """
        Create an SDK-compatible can_use_tool callback.

        Returns a function that can be passed to ClaudeCodeOptions.can_use_tool.
        The SDK expects a function with signature:
            async (tool_name: str, input_data: dict, context: ToolPermissionContext) -> PermissionResultAllow | PermissionResultDeny
        """
        # Import SDK types upfront
        try:
            from claude_code_sdk.types import PermissionResultAllow, PermissionResultDeny
        except ImportError:
            logger.warning("SDK types not available, permissions will use defaults")
            PermissionResultAllow = None
            PermissionResultDeny = None

        async def sdk_can_use_tool(
            tool_name: str,
            input_data: dict[str, Any],
            context: Any,  # ToolPermissionContext from SDK
        ):
            logger.debug(f"can_use_tool called: {tool_name}")

            # Check our permission handler
            decision = await self.check_permission(tool_name, input_data)

            logger.info(f"Permission decision for {tool_name}: {decision.behavior}")

            if PermissionResultAllow is None or PermissionResultDeny is None:
                # SDK types not available - return simple dict
                # The SDK may accept this as a fallback
                if decision.behavior == "allow":
                    return {"behavior": "allow", "updated_input": decision.updated_input}
                else:
                    return {"behavior": "deny", "message": decision.message or "Permission denied"}

            if decision.behavior == "allow":
                return PermissionResultAllow(updated_input=decision.updated_input)
            else:
                return PermissionResultDeny(
                    message=decision.message or "Permission denied",
                    interrupt=decision.interrupt,
                )

        return sdk_can_use_tool

    async def check_permission(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str] = None,
    ) -> PermissionDecision:
        """
        Check if a tool can be used.

        Args:
            tool_name: Name of the tool
            input_data: Tool input parameters
            tool_use_id: Unique ID for this tool use

        Returns:
            PermissionDecision indicating allow/deny
        """
        logger.debug(f"Permission check: {tool_name}")

        # TIER 1: Always allow read-only tools
        if tool_name in TIER1_ALWAYS_ALLOW:
            logger.debug(f"TIER 1 auto-allow: {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # TIER 3: MCP tools - check approval
        if tool_name.startswith("mcp__"):
            return await self._check_mcp_permission(tool_name, input_data, tool_use_id)

        # TIER 2: Write tools - check paths
        if tool_name in TIER2_WRITE_TOOLS:
            return await self._check_write_permission(tool_name, input_data, tool_use_id)

        # Unknown tool - allow by default
        logger.debug(f"Unknown tool allowed: {tool_name}")
        return PermissionDecision(behavior="allow", updated_input=input_data)

    async def _check_mcp_permission(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
    ) -> PermissionDecision:
        """Check permission for MCP tools."""
        parts = tool_name.split("__")
        mcp_server = parts[1] if len(parts) > 1 else "unknown"
        mcp_tool = parts[2] if len(parts) > 2 else "unknown"

        # Check session approval
        if mcp_server in self.approved_mcps:
            logger.debug(f"MCP auto-allow (session): {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Check agent config approval
        approved = self.agent.permissions.approved_mcps
        if mcp_server in approved or "*" in approved:
            logger.debug(f"MCP auto-allow (config): {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Need user approval
        return await self._request_approval(
            tool_name=tool_name,
            input_data=input_data,
            tool_use_id=tool_use_id,
            mcp_server=mcp_server,
            mcp_tool=mcp_tool,
        )

    async def _check_write_permission(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
    ) -> PermissionDecision:
        """Check permission for write tools."""
        # Get file path from input
        file_path = input_data.get("file_path") or input_data.get("path") or ""

        # Convert absolute paths to relative
        if file_path.startswith(self.vault_path):
            file_path = file_path[len(self.vault_path):].lstrip("/")

        # Check Bash commands
        if tool_name == "Bash":
            write_patterns = self.agent.permissions.write
            if "*" in write_patterns:
                logger.debug(f"Bash auto-allow (full write access)")
                return PermissionDecision(behavior="allow", updated_input=input_data)

            # Need approval for Bash without full write access
            return await self._request_approval(
                tool_name=tool_name,
                input_data=input_data,
                tool_use_id=tool_use_id,
                file_path=input_data.get("command", ""),
            )

        # Check file path against patterns
        if file_path:
            write_patterns = self.agent.permissions.write
            if matches_patterns(file_path, write_patterns):
                logger.debug(f"Write allowed by policy: {file_path}")
                return PermissionDecision(behavior="allow", updated_input=input_data)

            # Need approval
            return await self._request_approval(
                tool_name=tool_name,
                input_data=input_data,
                tool_use_id=tool_use_id,
                file_path=file_path,
                allowed_patterns=write_patterns,
            )

        # No path - allow
        return PermissionDecision(behavior="allow", updated_input=input_data)

    async def _request_approval(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
        file_path: Optional[str] = None,
        allowed_patterns: Optional[list[str]] = None,
        mcp_server: Optional[str] = None,
        mcp_tool: Optional[str] = None,
    ) -> PermissionDecision:
        """Request user approval for an operation."""
        if len(self.pending) >= self.max_pending:
            logger.warning("Too many pending permissions")
            if self.on_denial:
                self.on_denial({"tool_name": tool_name, "reason": "server_overloaded"})
            return PermissionDecision(
                behavior="deny",
                message="Server overloaded with permission requests",
            )

        request_id = f"{self.session_id}-{tool_use_id or uuid4().hex[:8]}"

        # Create promise-like for resolution
        loop = asyncio.get_event_loop()
        future: asyncio.Future[str] = loop.create_future()

        def resolve(decision: str) -> None:
            if not future.done():
                future.set_result(decision)

        request = PermissionRequest(
            id=request_id,
            tool_name=tool_name,
            input_data=input_data,
            agent_name=self.agent.name,
            file_path=file_path,
            allowed_patterns=allowed_patterns or [],
            mcp_server=mcp_server,
            mcp_tool=mcp_tool,
            _resolve=resolve,
        )

        self.pending[request_id] = request

        # Notify listeners
        if self.on_request:
            self.on_request(request)

        logger.info(f"Waiting for approval: {request_id}")

        # Wait for decision with timeout
        try:
            decision = await asyncio.wait_for(
                future, timeout=self.timeout_seconds
            )
        except asyncio.TimeoutError:
            decision = "timeout"

        # Clean up
        del self.pending[request_id]

        logger.info(f"Permission decision: {request_id} -> {decision}")

        if decision == "granted" or decision == "allow_session":
            if decision == "allow_session" and mcp_server:
                self.approved_mcps.add(mcp_server)
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Denied or timeout
        reason = "timeout" if decision == "timeout" else "denied"
        if self.on_denial:
            self.on_denial({
                "tool_name": tool_name,
                "file_path": file_path,
                "reason": reason,
            })

        return PermissionDecision(
            behavior="deny",
            message=f"Permission {reason} for {tool_name}",
        )

    def grant(self, request_id: str) -> bool:
        """Grant a pending permission request."""
        request = self.pending.get(request_id)
        if request and request.status == "pending" and request._resolve:
            request.status = "granted"
            request._resolve("granted")
            return True
        return False

    def deny(self, request_id: str) -> bool:
        """Deny a pending permission request."""
        request = self.pending.get(request_id)
        if request and request.status == "pending" and request._resolve:
            request.status = "denied"
            request._resolve("denied")
            return True
        return False

    def grant_session(self, request_id: str) -> bool:
        """Grant permission for the entire session (MCP tools)."""
        request = self.pending.get(request_id)
        if request and request.status == "pending" and request._resolve:
            request.status = "granted"
            request._resolve("allow_session")
            return True
        return False

    def get_pending(self) -> list[PermissionRequest]:
        """Get all pending permission requests."""
        return [r for r in self.pending.values() if r.status == "pending"]

    def cleanup_stale(self, max_age_seconds: int = 300) -> int:
        """Clean up stale permission requests."""
        now = datetime.utcnow()
        cleaned = 0

        for request_id in list(self.pending.keys()):
            request = self.pending[request_id]
            age = (now - request.timestamp).total_seconds()

            if age > max_age_seconds or request.status != "pending":
                del self.pending[request_id]
                cleaned += 1

        return cleaned
