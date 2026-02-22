"""
Permission handler for tool access control.

Implements session-based permission checking:
- Always allowed: MCP tools, WebSearch, WebFetch, limited Bash (ls, pwd, tree)
- Gated: Read, Write, Edit, full Bash - require session permissions
- Deny list: .env, credentials, etc. - always blocked

Session permissions are stored in session metadata and can be granted
dynamically via the permission_request SSE flow.
"""

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional
from uuid import uuid4

from parachute.lib.ignore_patterns import get_ignore_patterns
from parachute.models.session import Session, SessionPermissions, TrustLevel

logger = logging.getLogger(__name__)


# Tools that are always allowed (no permission needed)
ALWAYS_ALLOWED_TOOLS = [
    # MCP tools are always allowed - they provide structured vault access
    # (patterns: mcp__*)

    # Web tools
    "WebSearch",
    "WebFetch",

    # Task/agent delegation
    "Task",
    "TaskOutput",
]

# Read-only tools that require permission
READ_TOOLS = [
    "Read",
    "Glob",
    "Grep",
    "LS",
    "NotebookRead",
    "LSP",
]

# Write tools that require permission
WRITE_TOOLS = [
    "Write",
    "Edit",
    "MultiEdit",
    "NotebookEdit",
]

# Bash requires special handling
BASH_TOOL = "Bash"


@dataclass
class PermissionRequest:
    """A pending permission request."""

    id: str
    tool_name: str
    input_data: dict[str, Any]
    agent_name: str
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    status: str = "pending"  # pending, granted, denied, timeout

    # For write tools
    file_path: Optional[str] = None
    allowed_patterns: list[str] = field(default_factory=list)

    # For MCP tools
    mcp_server: Optional[str] = None
    mcp_tool: Optional[str] = None

    # Resolution
    _resolve: Optional[Callable[[str], None]] = field(default=None, repr=False)
    _future: Optional[asyncio.Future] = field(default=None, repr=False)


@dataclass
class UserQuestionRequest:
    """A pending user question request (from AskUserQuestion tool)."""

    id: str
    tool_use_id: str
    questions: list[dict[str, Any]]
    timestamp: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    status: str = "pending"  # pending, answered, timeout

    # Resolution - receives dict of question -> answer(s)
    _resolve: Optional[Callable[[dict[str, Any]], None]] = field(default=None, repr=False)
    _future: Optional[asyncio.Future] = field(default=None, repr=False)


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
    Uses session-based permissions with global deny list enforcement.
    """

    def __init__(
        self,
        session: Session,
        vault_path: str,
        on_denial: Optional[Callable[[dict[str, Any]], None]] = None,
        on_request: Optional[Callable[[PermissionRequest], None]] = None,
        on_permission_update: Optional[Callable[[SessionPermissions], None]] = None,
        on_user_question: Optional[Callable[[UserQuestionRequest], None]] = None,
    ):
        """
        Initialize permission handler.

        Args:
            session: Session with permissions in metadata
            vault_path: Path to vault root
            on_denial: Callback when permission is denied
            on_request: Callback when permission needs user approval
            on_permission_update: Callback when session permissions are updated
            on_user_question: Callback when Claude asks user a question (AskUserQuestion)
        """
        self.session = session
        self.vault_path = Path(vault_path)
        self.on_denial = on_denial
        self.on_request = on_request
        self.on_user_question = on_user_question
        self.on_permission_update = on_permission_update

        # Get session permissions (may be empty for new sessions)
        self._permissions = session.permissions

        # Global deny list
        self._ignore = get_ignore_patterns()

        # Pending permission requests
        self.pending: dict[str, PermissionRequest] = {}

        # Pending user questions (from AskUserQuestion tool)
        self.pending_questions: dict[str, UserQuestionRequest] = {}

        # Stash for AskUserQuestion tool_use_id — the orchestrator sets this
        # when it sees the tool_use block in the assistant message, before the
        # SDK calls can_use_tool.  This lets us build the same request_id that
        # the SSE event uses (the SDK doesn't expose tool_use_id in the callback).
        self.next_question_tool_use_id: Optional[str] = None

        # Limits
        self.max_pending = 100
        self.timeout_seconds = 120
        self.question_timeout_seconds = 300  # 5 minutes for user questions

    @property
    def permissions(self) -> SessionPermissions:
        """Get current session permissions."""
        return self._permissions

    def update_permissions(self, permissions: SessionPermissions) -> None:
        """Update session permissions (e.g., after user grants access)."""
        self._permissions = permissions
        if self.on_permission_update:
            self.on_permission_update(permissions)

    def create_sdk_callback(self):
        """
        Create an SDK-compatible can_use_tool callback.

        Returns a function that can be passed to ClaudeAgentOptions.can_use_tool.
        The SDK expects a function with signature:
            async (tool_name: str, input_data: dict, context: ToolPermissionContext) -> PermissionResultAllow | PermissionResultDeny
        """
        # Import SDK types upfront
        try:
            from claude_agent_sdk.types import PermissionResultAllow, PermissionResultDeny
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

            # Special handling for AskUserQuestion - needs interactive response
            if tool_name == "AskUserQuestion":
                logger.info(f"AskUserQuestion intercepted, awaiting user answer...")
                result = await self._handle_ask_user_question(input_data, context)
                logger.info(f"AskUserQuestion resolved")
                if PermissionResultAllow is None:
                    return {"behavior": "allow", "updated_input": result}
                return PermissionResultAllow(updated_input=result)

            # Check our permission handler
            decision = await self.check_permission(tool_name, input_data)

            logger.debug(f"Permission decision for {tool_name}: {decision.behavior}")

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

        # Resolve trust level
        trust_level = self._permissions.trust_level
        trust_mode = trust_level == TrustLevel.DIRECT

        # Sandboxed agents: deny all host tools - they run in Docker containers
        if trust_level == TrustLevel.SANDBOXED:
            # Only allow MCP tools and web tools in sandboxed mode
            if tool_name.startswith("mcp__") or tool_name in ALWAYS_ALLOWED_TOOLS:
                return PermissionDecision(behavior="allow", updated_input=input_data)
            return PermissionDecision(
                behavior="deny",
                message=f"Sandboxed agents cannot use host tool: {tool_name}",
            )

        # Always allow MCP tools (they provide structured access)
        if tool_name.startswith("mcp__"):
            logger.debug(f"MCP tool auto-allow: {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Always allow web tools and task delegation
        if tool_name in ALWAYS_ALLOWED_TOOLS:
            logger.debug(f"Always allowed: {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Bash requires special handling
        if tool_name == BASH_TOOL:
            return await self._check_bash_permission(input_data, tool_use_id, trust_mode)

        # Read tools - check read permission
        if tool_name in READ_TOOLS:
            return await self._check_read_permission(tool_name, input_data, tool_use_id, trust_mode)

        # Write tools - check write permission
        if tool_name in WRITE_TOOLS:
            return await self._check_write_permission(tool_name, input_data, tool_use_id, trust_mode)

        # Unknown tool - allow in trust mode, deny otherwise
        if trust_mode:
            logger.debug(f"Unknown tool allowed (trust mode): {tool_name}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        logger.warning(f"Unknown tool denied: {tool_name}")
        return PermissionDecision(
            behavior="deny",
            message=f"Unknown tool: {tool_name}",
        )

    def _to_relative_path(self, path: str) -> str:
        """Convert an absolute path to a vault-relative path."""
        try:
            abs_path = Path(path).resolve()
            if abs_path.is_relative_to(self.vault_path):
                return str(abs_path.relative_to(self.vault_path))
            return path
        except (ValueError, OSError):
            return path

    async def _check_read_permission(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
        trust_mode: bool,
    ) -> PermissionDecision:
        """Check permission for read tools."""
        # Get file path from input
        file_path = input_data.get("file_path") or input_data.get("path") or ""
        relative_path = self._to_relative_path(file_path)

        # Check deny list first (always enforced)
        if relative_path and self._ignore.is_denied(relative_path):
            logger.warning(f"Read denied by ignore list: {relative_path}")
            if self.on_denial:
                self.on_denial({
                    "tool_name": tool_name,
                    "file_path": relative_path,
                    "reason": "denied_by_ignore_list",
                })
            return PermissionDecision(
                behavior="deny",
                message=f"Access denied: {relative_path} matches security pattern",
            )

        # Trust mode allows all (after deny list check)
        if trust_mode:
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Check session permissions
        if relative_path and self._permissions.can_read(relative_path):
            logger.debug(f"Read allowed by permission: {relative_path}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # No permission - request approval
        return await self._request_approval(
            tool_name=tool_name,
            input_data=input_data,
            tool_use_id=tool_use_id,
            file_path=relative_path,
            permission_type="read",
        )

    async def _check_write_permission(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
        trust_mode: bool,
    ) -> PermissionDecision:
        """Check permission for write tools."""
        # Get file path from input
        file_path = input_data.get("file_path") or input_data.get("path") or ""
        relative_path = self._to_relative_path(file_path)

        # Check deny list first (always enforced)
        if relative_path and self._ignore.is_denied(relative_path):
            logger.warning(f"Write denied by ignore list: {relative_path}")
            if self.on_denial:
                self.on_denial({
                    "tool_name": tool_name,
                    "file_path": relative_path,
                    "reason": "denied_by_ignore_list",
                })
            return PermissionDecision(
                behavior="deny",
                message=f"Access denied: {relative_path} matches security pattern",
            )

        # Trust mode allows all (after deny list check)
        if trust_mode:
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Check session permissions
        if relative_path and self._permissions.can_write(relative_path):
            logger.debug(f"Write allowed by permission: {relative_path}")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # No permission - request approval
        return await self._request_approval(
            tool_name=tool_name,
            input_data=input_data,
            tool_use_id=tool_use_id,
            file_path=relative_path,
            permission_type="write",
        )

    async def _check_bash_permission(
        self,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
        trust_mode: bool,
    ) -> PermissionDecision:
        """Check permission for Bash commands."""
        command = input_data.get("command", "")

        # Check for dangerous commands (always blocked)
        dangerous = self._is_dangerous_command(command)
        if dangerous:
            logger.warning(f"Bash denied (dangerous): {command[:50]}...")
            if self.on_denial:
                self.on_denial({
                    "tool_name": BASH_TOOL,
                    "command": command,
                    "reason": dangerous,
                })
            return PermissionDecision(
                behavior="deny",
                message=dangerous,
            )

        # Trust mode allows all safe commands
        if trust_mode:
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # Check session permissions
        if self._permissions.can_bash(command):
            logger.debug(f"Bash allowed by permission: {command[:30]}...")
            return PermissionDecision(behavior="allow", updated_input=input_data)

        # No permission - request approval
        return await self._request_approval(
            tool_name=BASH_TOOL,
            input_data=input_data,
            tool_use_id=tool_use_id,
            file_path=command,
            permission_type="bash",
        )

    def _is_dangerous_command(self, command: str) -> Optional[str]:
        """
        Check if a command is inherently dangerous.

        Returns the reason if dangerous, None if OK.
        """
        cmd_lower = command.lower().strip()

        blocked_commands = [
            ("sudo", "sudo commands are not allowed"),
            ("rm -rf /", "Cannot delete root filesystem"),
            ("rm -rf ~", "Cannot delete home directory"),
            ("rm -rf /*", "Cannot delete root filesystem"),
            (":(){:|:&};:", "Fork bomb detected"),
            ("mkfs", "Cannot format filesystems"),
            ("dd if=", "Direct disk access not allowed"),
            ("> /dev/", "Cannot write to device files"),
            ("chmod -R 777 /", "Cannot change permissions on root"),
        ]

        for pattern, reason in blocked_commands:
            if pattern in cmd_lower:
                return reason

        return None

    async def _request_approval(
        self,
        tool_name: str,
        input_data: dict[str, Any],
        tool_use_id: Optional[str],
        file_path: Optional[str] = None,
        permission_type: str = "write",  # "read", "write", or "bash"
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

        request_id = f"{self.session.id}-{tool_use_id or uuid4().hex[:8]}"

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
            agent_name="vault-agent",
            file_path=file_path,
            allowed_patterns=self._permissions.read if permission_type == "read" else self._permissions.write,
            _resolve=resolve,
            _future=future,
        )

        self.pending[request_id] = request

        # Notify listeners (this triggers the SSE event)
        if self.on_request:
            self.on_request(request)

        logger.info(f"Waiting for approval: {request_id} ({permission_type} {file_path})")

        # Wait for decision with timeout, ensuring cleanup on any exit path
        try:
            try:
                decision = await asyncio.wait_for(
                    future, timeout=self.timeout_seconds
                )
            except asyncio.TimeoutError:
                decision = "timeout"

            logger.info(f"Permission decision: {request_id} -> {decision}")

            if decision.startswith("granted"):
                # Handle permission grants with pattern
                # Format: "granted:pattern" or just "granted"
                if ":" in decision:
                    pattern = decision.split(":", 1)[1]
                    self._add_permission(permission_type, pattern)
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
        finally:
            self.pending.pop(request_id, None)

    def _add_permission(self, permission_type: str, pattern: str) -> None:
        """Add a permission pattern to the session."""
        if permission_type == "read":
            if pattern not in self._permissions.read:
                new_read = self._permissions.read + [pattern]
                self._permissions = SessionPermissions(
                    read=new_read,
                    write=self._permissions.write,
                    bash=self._permissions.bash,
                    trustLevel=self._permissions.trust_level,
                )
        elif permission_type == "write":
            if pattern not in self._permissions.write:
                new_write = self._permissions.write + [pattern]
                self._permissions = SessionPermissions(
                    read=self._permissions.read,
                    write=new_write,
                    bash=self._permissions.bash,
                    trustLevel=self._permissions.trust_level,
                )
        elif permission_type == "bash":
            if isinstance(self._permissions.bash, list) and pattern not in self._permissions.bash:
                new_bash = self._permissions.bash + [pattern]
                self._permissions = SessionPermissions(
                    read=self._permissions.read,
                    write=self._permissions.write,
                    bash=new_bash,
                    trustLevel=self._permissions.trust_level,
                )

        # Notify about permission update
        if self.on_permission_update:
            self.on_permission_update(self._permissions)

    def grant(self, request_id: str, pattern: Optional[str] = None) -> bool:
        """
        Grant a pending permission request.

        Args:
            request_id: The request ID to grant
            pattern: Optional glob pattern for the grant (e.g., "Blogs/**/*")
                    If not provided, grants access to the specific file only.
        """
        request = self.pending.get(request_id)
        if request and request.status == "pending" and request._resolve:
            request.status = "granted"
            if pattern:
                request._resolve(f"granted:{pattern}")
            else:
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

    def get_pending(self) -> list[PermissionRequest]:
        """Get all pending permission requests."""
        return [r for r in self.pending.values() if r.status == "pending"]

    def cleanup(self) -> None:
        """Force-resolve all pending futures and clear state. Called on session end."""
        cleaned_approvals = 0
        cleaned_questions = 0

        for request_id, request in list(self.pending.items()):
            if request._future and not request._future.done():
                try:
                    request._future.set_result("denied")
                except asyncio.InvalidStateError:
                    pass  # Future cancelled between done() check and set_result()
                cleaned_approvals += 1
        self.pending.clear()

        for request_id, request in list(self.pending_questions.items()):
            if request._future and not request._future.done():
                try:
                    request._future.set_result({})
                except asyncio.InvalidStateError:
                    pass
                cleaned_questions += 1
        self.pending_questions.clear()

        if cleaned_approvals or cleaned_questions:
            logger.warning(
                "Cleaned up %d pending approvals and %d pending questions for session %s",
                cleaned_approvals, cleaned_questions, self.session.id
            )

    def cleanup_stale(self, max_age_seconds: int = 600) -> int:
        """Clean up stale permission requests. Resolves futures before removing."""
        now = datetime.now(timezone.utc)
        cleaned = 0

        for request_id, request in list(self.pending.items()):
            age = (now - request.timestamp).total_seconds()
            if age > max_age_seconds:
                if request._future and not request._future.done():
                    try:
                        request._future.set_result("denied")
                    except asyncio.InvalidStateError:
                        pass
                self.pending.pop(request_id, None)
                cleaned += 1

        for request_id, request in list(self.pending_questions.items()):
            age = (now - request.timestamp).total_seconds()
            if age > max_age_seconds:
                if request._future and not request._future.done():
                    try:
                        request._future.set_result({})
                    except asyncio.InvalidStateError:
                        pass
                self.pending_questions.pop(request_id, None)
                cleaned += 1

        return cleaned

    def get_suggested_grants(self, path: str) -> list[dict[str, str]]:
        """
        Get suggested permission grants for a path.

        Returns a list of grant options from most specific to most broad.
        """
        parts = Path(path).parts
        suggestions = []

        # Option 1: Just this file
        suggestions.append({
            "scope": "file",
            "pattern": path,
            "label": f"This file only ({Path(path).name})",
        })

        # Option 2: This folder
        if len(parts) > 1:
            folder = str(Path(*parts[:-1]))
            suggestions.append({
                "scope": "folder",
                "pattern": f"{folder}/*",
                "label": f"{folder}/ folder",
            })

        # Option 3: This folder recursively
        if len(parts) > 1:
            folder = str(Path(*parts[:-1]))
            suggestions.append({
                "scope": "recursive",
                "pattern": f"{folder}/**/*",
                "label": f"{folder}/ and subfolders",
            })

        # Option 4: Root folder (if nested)
        if len(parts) > 2:
            root_folder = parts[0]
            suggestions.append({
                "scope": "root",
                "pattern": f"{root_folder}/**/*",
                "label": f"All of {root_folder}/",
            })

        # Option 5: Full vault access (trust mode)
        suggestions.append({
            "scope": "vault",
            "pattern": "**/*",
            "label": "Full vault access",
        })

        return suggestions

    # -------------------------------------------------------------------------
    # AskUserQuestion handling
    # -------------------------------------------------------------------------

    async def _handle_ask_user_question(
        self,
        input_data: dict[str, Any],
        context: Any,
    ) -> dict[str, Any]:
        """
        Handle AskUserQuestion tool call by waiting for user response.

        Args:
            input_data: Tool input containing 'questions' list
            context: SDK context (contains tool_use_id if available)

        Returns:
            Updated input with 'answers' dict added
        """
        questions = input_data.get("questions", [])
        if not questions:
            logger.warning("AskUserQuestion called with no questions")
            return input_data

        # Generate request ID — prefer the tool_use_id stashed by the
        # orchestrator (from the assistant message block) so it matches the
        # request_id sent to the client in the SSE user_question event.
        tool_use_id = self.next_question_tool_use_id or uuid4().hex[:8]
        self.next_question_tool_use_id = None  # consume it
        request_id = f"{self.session.id}-q-{tool_use_id}"

        logger.info(f"AskUserQuestion: {len(questions)} questions, request_id={request_id}")

        # Create promise-like for resolution
        loop = asyncio.get_event_loop()
        future: asyncio.Future[dict[str, Any]] = loop.create_future()

        def resolve(answers: dict[str, Any]) -> None:
            if not future.done():
                future.set_result(answers)

        request = UserQuestionRequest(
            id=request_id,
            tool_use_id=tool_use_id,
            questions=questions,
            _resolve=resolve,
            _future=future,
        )

        self.pending_questions[request_id] = request

        # Notify listeners (triggers SSE event to client)
        if self.on_user_question:
            self.on_user_question(request)

        # Wait for user response with timeout, ensuring cleanup on any exit path
        try:
            try:
                answers = await asyncio.wait_for(
                    future, timeout=self.question_timeout_seconds
                )
                request.status = "answered"
            except asyncio.TimeoutError:
                logger.warning(f"AskUserQuestion timeout: {request_id}")
                request.status = "timeout"
                # Return empty answers on timeout - Claude will see no response
                answers = {}

            # Return updated input with answers
            return {
                "questions": questions,
                "answers": answers,
            }
        finally:
            self.pending_questions.pop(request_id, None)

    def answer_questions(self, request_id: str, answers: dict[str, Any]) -> bool:
        """
        Submit answers to a pending AskUserQuestion request.

        Args:
            request_id: The request ID to answer
            answers: Dict mapping question text to selected answer(s)

        Returns:
            True if request was found and answered, False otherwise
        """
        request = self.pending_questions.get(request_id)
        if request and request.status == "pending" and request._resolve:
            request._resolve(answers)
            return True
        return False

    def get_pending_questions(self) -> list[UserQuestionRequest]:
        """Get all pending user question requests."""
        return [r for r in self.pending_questions.values() if r.status == "pending"]
