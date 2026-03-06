"""
Agent Orchestrator

Central controller that manages agent execution:
- Loads agents from markdown definitions
- Manages sessions via SQLite
- Runs agents via Claude SDK
- Handles streaming responses
- Enforces permissions
"""

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any, AsyncGenerator, Optional

from parachute.config import Settings, get_settings
from parachute.core.claude_sdk import query_streaming, QueryInterrupt
from parachute.core.permission_handler import PermissionHandler
from parachute.core.sandbox import DockerSandbox, AgentSandboxConfig
from parachute.core.session_manager import SessionManager
from parachute.db.brain_sessions import BrainSessionStore
from parachute.lib.context_loader import format_context_for_prompt, load_agent_context
from parachute.lib.credentials import load_credentials
from parachute.core.context_folders import ContextFolderService
from parachute.core.capability_filter import filter_by_trust_level
from parachute.lib.mcp_loader import (
    load_mcp_servers,
    resolve_mcp_servers,
    validate_and_filter_servers,
)
from parachute.models.agent import AgentDefinition, create_vault_agent
from parachute.lib.typed_errors import ErrorCode, parse_error
from parachute.models.events import (
    AbortedEvent,
    DoneEvent,
    ErrorEvent,
    InitEvent,
    ModelEvent,
    PromptMetadataEvent,
    SessionEvent,
    SessionUnavailableEvent,
    TextEvent,
    ThinkingEvent,
    ToolResultEvent,
    ToolUseEvent,
    TypedErrorEvent,
    UserMessageEvent,
    UserQuestionEvent,
    WarningEvent,
)
from parachute.models.session import (
    BOT_SOURCES,
    Session,
    SessionSource,
    SessionUpdate,
    TrustLevel,
)

logger = logging.getLogger(__name__)


def generate_title_from_message(message: str, max_length: int = 60) -> str:
    """
    Generate a session title from the first user message.

    Takes the first line or sentence, truncates to max_length.
    """
    # Take first line
    first_line = message.split("\n")[0].strip()

    # If too long, truncate at word boundary
    if len(first_line) > max_length:
        truncated = first_line[:max_length]
        # Try to break at last space
        last_space = truncated.rfind(" ")
        if last_space > max_length // 2:
            truncated = truncated[:last_space]
        return truncated + "..."

    return first_line


def _set_title_source(session: Session, source: str) -> None:
    """Set title_source in session metadata (mutates the placeholder before finalization)."""
    if session.metadata is None:
        session.metadata = {}
    session.metadata["title_source"] = source


# System prompt for converse mode — full replacement, no Claude Code preset
CONVERSE_PROMPT = """# Parachute

You are Parachute, a thinking partner and memory extension.

## Your Role
Help the user think clearly, explore ideas, remember context, and make connections.
This is a collaborative thinking relationship — not a task queue.

## How to Engage
- Think alongside, not just for — ask questions that help develop their thinking
- Be direct: skip flattery, no filler phrases, respond to what's actually being asked
- Make connections between what you know about their projects, interests, and past thinking
- One question at a time — pick the best one, not all of them

## Vault Context
Search the vault when the user asks about their own thoughts, projects, or history,
or when personalized context would improve your response.

### Vault Tools (mcp__parachute__*)
- **mcp__parachute__search_sessions** — search past conversations
- **mcp__parachute__list_recent_sessions** — recent chat sessions
- **mcp__parachute__get_session** — read a specific conversation
- **mcp__parachute__search_journals** — search Daily voice journal entries
- **mcp__parachute__list_recent_journals** — recent journal dates
- **mcp__parachute__get_journal** — read a specific day's journal

### Web Tools
- **WebSearch** — current information, news, research
- **WebFetch** — read a specific URL

## Handling Attachments
- **Images**: Use the Read tool to view and describe them — don't just acknowledge
- **PDFs / text files**: Read and engage with the content directly

## Skills
Skills in `.claude/skills/` extend your capabilities for specific tasks.
When a task seems to call for one, invoke it with the Skill tool.
"""

# Append content for cocreate mode — added on top of Claude Code preset
COCREATE_PROMPT_APPEND = """## Parachute Context

You are running as Parachute in cocreate mode — an agentic partner for building,
writing, coding, and creating. The project's CLAUDE.md or AGENTS.md defines
conventions and orientation for this specific context.

## Vault Tools Available (mcp__parachute__*)
The same vault tools from converse mode are available for personal context:
search_sessions, search_journals, get_journal, list_recent_sessions, etc.

## Working Style
- For multi-step tasks, use TodoWrite to track progress visibly
- Clarify ambiguous requests before executing — simple-sounding tasks are often
  underspecified; asking once upfront prevents wasted effort
- Loop in the user at natural checkpoints, especially before irreversible actions
"""


class InjectResult(StrEnum):
    """Result of a mid-stream message injection attempt."""

    OK = "ok"
    NO_STREAM = "no_stream"
    QUEUE_FULL = "queue_full"


@dataclass
class CapabilityBundle:
    """Resolved capabilities for a run_streaming() call."""

    resolved_mcps: dict | None
    plugin_dirs: list[Path]
    agents_dict: dict | None
    effective_trust: str
    warnings: list[dict] = field(default_factory=list)  # Serialized WarningEvent dicts


@dataclass
class _SandboxCallContext:
    """Per-call state for sandbox event processing (replaces 9-variable closure)."""

    sbx: dict  # mutable state bag — contains "message", "session", "had_text", etc.
    sandbox_sid: str
    effective_trust: str
    is_new: bool
    captured_model: str | None
    agent_type: str | None
    effective_working_dir: str | None
    mode: str = "converse"


class Orchestrator:
    """
    Central agent execution controller.

    Manages the lifecycle of agent interactions with streaming support.
    """

    def __init__(
        self, parachute_dir: Path, session_store: BrainSessionStore, settings: Settings
    ):
        """Initialize orchestrator."""
        self.parachute_dir = parachute_dir
        self.session_store = session_store
        self.settings = settings

        # Session manager
        self.session_manager = SessionManager(parachute_dir, session_store)

        # Shared Docker sandbox instance (TTL-cached availability checks)
        self._sandbox = DockerSandbox(
            parachute_dir=parachute_dir,
            claude_token=settings.claude_code_oauth_token,
        )

        # Active streams for abort functionality
        self.active_streams: dict[str, QueryInterrupt] = {}

        # Message queues for mid-stream message injection
        self.active_stream_queues: dict[str, asyncio.Queue[str]] = {}

        # Pending permission requests
        self.pending_permissions: dict[str, PermissionHandler] = {}

    @property
    def sandbox(self) -> DockerSandbox:
        """Public access to the Docker sandbox instance."""
        return self._sandbox

    async def delete_container(self, slug: str) -> None:
        """Stop and remove a container env (container + vault home dir)."""
        await self._sandbox.delete_container(slug)

    async def reconcile_containers(self) -> None:
        """Reconcile sandbox containers on startup."""
        # Remove project records for envs where every session is empty
        # (message_count == 0) and the env is older than 5 minutes. These are
        # abandoned or failed sessions that never sent a message.
        orphan_slugs = await self.session_store.list_orphan_project_slugs(
            min_age_minutes=5
        )
        if orphan_slugs:
            logger.info(
                f"Pruning {len(orphan_slugs)} orphan project record(s): {orphan_slugs}"
            )
            for slug in orphan_slugs:
                try:
                    await self.session_store.delete_project(slug)
                except Exception as e:
                    logger.warning(f"Failed to delete orphan project {slug}: {e}")

        # Use remaining project slugs for Docker orphan detection
        active_envs = await self.session_store.list_projects()
        active_slugs = {env.slug for env in active_envs}
        await self._sandbox.reconcile(active_slugs=active_slugs)

    async def run_streaming(
        self,
        message: str,
        session_id: Optional[str] = None,
        module: str = "chat",
        system_prompt: Optional[str] = None,
        working_directory: Optional[str] = None,
        agent_path: Optional[str] = None,
        initial_context: Optional[str] = None,
        prior_conversation: Optional[str] = None,
        contexts: Optional[list[str]] = None,
        recovery_mode: Optional[str] = None,
        attachments: Optional[list[dict[str, Any]]] = None,
        agent_type: Optional[str] = None,
        trust_level: Optional[str] = None,
        mode: Optional[str] = None,
        model: Optional[str] = None,
        container_id: Optional[str] = None,
    ) -> AsyncGenerator[dict[str, Any], None]:
        """
        Run an agent with streaming response.

        This is the main entry point for chat interactions.  Thin coordinator
        that delegates to four private phase methods:

        1. ``_save_attachments()``   — save base64 attachments to vault
        2. ``_discover_capabilities()`` — MCP / skills / plugin / trust resolution
        3. ``_run_trusted()``        — direct SDK execution path
        4. ``_run_sandboxed()``      — Docker container execution path

        Yields:
            SSE events as dictionaries
        """
        start_time = time.time()

        # Load agent — always use the built-in vault-agent.
        # Custom agents are discovered by the SDK via .claude/agents/ (setting_sources=["project"]).
        logger.info(
            f"run_streaming: agent_path={agent_path!r}, agent_type={agent_type!r}"
        )
        if agent_path and agent_path != "vault-agent":
            logger.info(
                f"Ignoring agent_path={agent_path!r} — SDK handles agent discovery natively"
            )
        agent = create_vault_agent()

        # Get or create session (before building prompt so we can load prior conversation)
        session, resume_info, is_new = await self.session_manager.get_or_create_session(
            session_id=session_id,
            module=module,
            working_directory=working_directory,
            trust_level=trust_level,
            mode=mode,
            project_id=container_id,
        )

        # For imported sessions, handle context continuity
        # - Claude Code sessions with existing JSONL: use SDK resume directly
        # - Other imports (Claude Web, ChatGPT): inject history as context
        effective_prior_conversation = prior_conversation
        imported_sources = (
            SessionSource.CLAUDE_CODE,
            SessionSource.CLAUDE_WEB,
            SessionSource.CHATGPT,
        )
        if not prior_conversation and session.source in imported_sources:
            # Check if SDK can resume this session directly
            sdk_can_resume = self.session_manager._check_sdk_session_exists(
                session.id, session.working_directory
            )

            if session.source == SessionSource.CLAUDE_CODE and sdk_can_resume:
                # Claude Code session with existing JSONL - let SDK resume directly
                logger.info(
                    f"Claude Code session has JSONL, using SDK resume: {session.id[:8]}..."
                )
                # Don't inject prior conversation, don't force is_new
                # SDK will load the full history automatically
            else:
                # No SDK file or non-Claude-Code import - inject as context
                loaded_prior = await self.session_manager.get_prior_conversation(
                    session
                )
                if loaded_prior:
                    effective_prior_conversation = loaded_prior
                    logger.info(
                        f"Loaded prior conversation for {session.source.value} session: {session.id[:8]}..."
                    )
                    # Force new SDK session since we're injecting context, not resuming
                    is_new = True

        # Extract config overrides from session metadata (set via PATCH /config endpoint)
        config_overrides = (
            (session.metadata or {}).get("config_overrides", {})
            if hasattr(session, "metadata")
            else {}
        )

        # Determine working directory first (needed for prompt building)
        # Priority: explicit param > config_overrides > session's stored value > vault path
        # Note: working_directory is stored as RELATIVE to vault_path in the database
        override_working_dir = config_overrides.get("working_directory")
        effective_working_dir: Optional[str] = (
            working_directory or override_working_dir or session.working_directory
        )
        effective_cwd = self.session_manager.resolve_working_directory(
            effective_working_dir
        )

        # For existing sessions, always verify the transcript's cwd so the SDK
        # can locate the JSONL file via path encoding.  A session with
        # workingDirectory=None resolves to Path.home() which exists, but the
        # transcript may live in a completely different project directory.
        if not is_new and session.id != "pending":
            resume_cwd = self.session_manager.get_session_resume_cwd(session.id)
            if resume_cwd and str(resume_cwd) != str(effective_cwd):
                logger.info(
                    f"Overriding working directory {effective_cwd} → {resume_cwd} "
                    f"to match transcript location for SDK resume"
                )
                effective_cwd = Path(resume_cwd)
                effective_working_dir = resume_cwd
            elif not effective_cwd.exists():
                logger.warning(
                    f"Working directory does not exist: {effective_cwd}, "
                    f"falling back to home directory"
                )
                effective_cwd = Path.home()
                effective_working_dir = None
        elif not effective_cwd.exists():
            logger.warning(
                f"Working directory does not exist: {effective_cwd}, "
                f"falling back to home directory"
            )
            effective_cwd = Path.home()
            effective_working_dir = None

        # Apply system prompt override from config_overrides (only if no explicit prompt given)
        override_system_prompt = config_overrides.get("system_prompt")
        effective_custom_prompt = system_prompt or override_system_prompt

        # Resolve effective mode: request > session > default ("converse")
        effective_mode = mode or getattr(session, "mode", None) or "converse"

        # Load project core_memory if session belongs to a project
        project_memory: Optional[str] = None
        if session.project_id:
            project = await self.session_store.get_project(session.project_id)
            if project and project.core_memory:
                project_memory = project.core_memory[:4000]

        # Build system prompt (after loading prior conversation, with working dir)
        # Only surface credential discoverability for non-bot sessions — bot sessions
        # receive empty credentials, so advertising pre-authenticated tools would mislead the agent.
        prompt_cred_keys = (
            set(load_credentials(Path.home()).keys())
            if session.source not in BOT_SOURCES
            else set()
        )
        effective_prompt, prompt_metadata = await self._build_system_prompt(
            agent=agent,
            custom_prompt=effective_custom_prompt,
            contexts=contexts,
            prior_conversation=effective_prior_conversation,
            working_directory=effective_working_dir,
            credential_keys=prompt_cred_keys,
            mode=effective_mode,
            project_memory=project_memory,
        )

        logger.info(
            f"Streaming session: sdk={session.id[:8] if session.id != 'pending' else 'new'}... "
            f"cwd={effective_cwd} is_new={is_new}"
        )

        # Yield session event
        yield SessionEvent(
            session_id=session.id if session.id != "pending" else None,
            working_directory=working_directory,
            resume_info=resume_info.model_dump(),
            trust_level=trust_level,
        ).model_dump(by_alias=True)

        # NOTE: PromptMetadataEvent is yielded after capability discovery (below)
        # so it can include available_agents, available_skills, and available_mcps.

        # Handle initial context
        actual_message = message
        if initial_context and is_new:
            if not message.strip():
                actual_message = initial_context
            else:
                actual_message = (
                    f"## Context\n\n{initial_context}\n\n---\n\n## Request\n\n{message}"
                )

        # Phase 1b: Save attachments and append to message
        attachment_block, attachment_failures = self._save_attachments(
            attachments or []
        )
        if attachment_block:
            actual_message = f"{actual_message}\n\n## Attachments\n\n{attachment_block}"

        # Emit user message event immediately so clients can display it
        # This ensures the user's message is visible even if they rejoin mid-stream
        # (SDK doesn't write user messages to JSONL until response completes)
        logger.info(f"Emitting user_message event: {message[:50]}...")
        yield UserMessageEvent(content=message).model_dump(by_alias=True)

        # Yield attachment warning after user message (user sees their message first)
        if attachment_failures:
            yield WarningEvent(
                code=ErrorCode.ATTACHMENT_SAVE_FAILED,
                title="Attachment Failed",
                message=f"Failed to save {len(attachment_failures)} attachment(s).",
                details=attachment_failures[:5],
                session_id=session.id if session.id != "pending" else None,
            ).model_dump(by_alias=True)

        # Handle recovery mode
        force_new = False
        if recovery_mode == "inject_context":
            # TODO: Inject context from session history
            force_new = True
        elif recovery_mode == "fresh_start":
            force_new = True

        # Set up interrupt handler and message injection queue
        interrupt = QueryInterrupt()
        message_queue: asyncio.Queue[str] = asyncio.Queue(maxsize=20)
        stream_session_id = session.id if session.id != "pending" else None
        if stream_session_id:
            self.active_streams[stream_session_id] = interrupt
            self.active_stream_queues[stream_session_id] = message_queue

        # permission_handler is None until Phase 2 completes; safe for finally block
        permission_handler = None

        try:
            # Phase 2: Capability discovery
            caps = await self._discover_capabilities(agent, session, trust_level)

            # converse mode always uses a full replacement prompt (no Claude Code preset)
            is_full_prompt = prompt_metadata.get("prompt_source") in ("custom", "agent", "converse")

            yield PromptMetadataEvent(
                prompt_source=prompt_metadata["prompt_source"],
                prompt_source_path=prompt_metadata["prompt_source_path"],
                context_files=prompt_metadata["context_files"],
                context_tokens=prompt_metadata["context_tokens"],
                context_truncated=prompt_metadata["context_truncated"],
                agent_name=prompt_metadata["agent_name"],
                available_agents=list(caps.agents_dict.keys())
                if caps.agents_dict
                else [],
                available_mcps=list(caps.resolved_mcps.keys())
                if caps.resolved_mcps
                else [],
                base_prompt_tokens=prompt_metadata["base_prompt_tokens"],
                total_prompt_tokens=prompt_metadata["total_prompt_tokens"],
                trust_mode=(session.permissions.trust_level == TrustLevel.DIRECT),
                working_directory_claude_md=prompt_metadata.get(
                    "working_directory_claude_md"
                ),
            ).model_dump(by_alias=True)

            # Yield MCP warnings returned by _discover_capabilities
            for warning in caps.warnings:
                yield warning

            # Phase 3: Set up permission handler
            permission_denials: list[dict[str, Any]] = []

            def on_permission_denial(denial: dict) -> None:
                permission_denials.append(denial)

            def on_user_question(request) -> None:
                logger.info(
                    f"User question registered: {request.id} with {len(request.questions)} questions"
                )

            permission_handler = PermissionHandler(
                session=session,
                vault_path=str(Path.home()),
                on_denial=on_permission_denial,
                on_user_question=on_user_question,
            )
            self.pending_permissions[session.id] = permission_handler

            # Determine resume session ID
            # Only resume if: session exists in DB, not new, not forced fresh,
            # and SDK actually has a JSONL transcript for this session.
            resume_id = None
            if session.id != "pending" and not is_new and not force_new:
                if self.session_manager._check_sdk_session_exists(
                    session.id, session.working_directory
                ):
                    resume_id = session.id
                else:
                    logger.info(
                        f"Session {session.id[:8]} exists in DB but has no SDK transcript "
                        f"(working_dir={session.working_directory!r}), treating as new"
                    )
                    is_new = True

            claude_token = get_settings().claude_code_oauth_token
            logger.info(
                f"Resume decision: session.id={session.id}, is_new={is_new}, "
                f"force_new={force_new}, resume_id={resume_id}"
            )

            # Phase 4: Execute (sandboxed or trusted)
            # Pre-check Docker availability so we can fall back to trusted for
            # local sessions without requiring _run_sandboxed() to signal this.
            run_trusted = caps.effective_trust != "sandboxed"
            if caps.effective_trust == "sandboxed":
                if await self._sandbox.is_available():
                    async for event in self._run_sandboxed(
                        session=session,
                        caps=caps,
                        actual_message=actual_message,
                        effective_prompt=effective_prompt,
                        is_full_prompt=is_full_prompt,
                        effective_working_dir=effective_working_dir,
                        is_new=is_new,
                        model=model,
                        message=message,
                        agent_type=agent_type,
                        captured_model=None,
                        mode=effective_mode,
                    ):
                        yield event
                elif session.source in BOT_SOURCES:
                    logger.error(
                        f"Docker unavailable for bot session {session.id[:8]} "
                        f"(source={session.source.value}) — hard failing"
                    )
                    yield ErrorEvent(
                        error="Docker is required for external sessions but is not available. "
                        "Contact the server administrator.",
                    ).model_dump(by_alias=True)
                else:
                    logger.warning(
                        f"Docker unavailable for session {session.id[:8]} — "
                        f"falling back to direct execution"
                    )
                    yield WarningEvent(
                        code=ErrorCode.SERVICE_UNAVAILABLE,
                        title="Running Without Sandbox",
                        message="Docker is not available. Running in direct mode — no sandboxing active.",
                        session_id=session.id if session.id != "pending" else None,
                    ).model_dump(by_alias=True)
                    run_trusted = True

            if run_trusted:
                async for event in self._run_trusted(
                    session=session,
                    caps=caps,
                    actual_message=actual_message,
                    effective_prompt=effective_prompt,
                    is_full_prompt=is_full_prompt,
                    effective_cwd=effective_cwd,
                    resume_id=resume_id,
                    model=model,
                    claude_token=claude_token,
                    message_queue=message_queue,
                    interrupt=interrupt,
                    permission_handler=permission_handler,
                    permission_denials=permission_denials,
                    is_new=is_new,
                    message=message,
                    working_directory=working_directory,
                    agent_type=agent_type,
                    resume_info=resume_info,
                    start_time=start_time,
                    mode=effective_mode,
                ):
                    yield event

        except asyncio.CancelledError:
            # Pre-stream cancellation (during capability discovery / setup).
            # During-stream cancellation is handled by _run_trusted / _run_sandboxed
            # which yield an AbortedEvent before re-raising here.
            raise

        except Exception as e:
            logger.error(f"Streaming error: {e}", exc_info=True)
            if "ENOENT" in str(e) or "not found" in str(e).lower():
                yield SessionUnavailableEvent(
                    reason="sdk_session_not_found",
                    session_id=session.id,
                    has_markdown_history=False,
                    message_count=0,
                    message="The conversation history could not be loaded.",
                ).model_dump(by_alias=True)
            else:
                typed = parse_error(e)
                yield TypedErrorEvent.from_typed_error(
                    typed, session_id=session.id
                ).model_dump(by_alias=True)

        finally:
            # Clean up active streams
            if stream_session_id:
                self.active_streams.pop(stream_session_id, None)
                self.active_stream_queues.pop(stream_session_id, None)

            # Clean up permission handler — find by object identity since
            # _run_trusted may have moved it to a finalized session ID key.
            if permission_handler:
                for k in list(self.pending_permissions.keys()):
                    if self.pending_permissions.get(k) is permission_handler:
                        self.pending_permissions.pop(k)
                permission_handler.cleanup()

    # =========================================================================
    # Private Phase Methods (extracted from run_streaming for readability)
    # =========================================================================

    def _save_attachments(
        self, attachments: list[dict[str, Any]]
    ) -> tuple[str, list[str]]:
        """Save base64 attachments to vault and return (markdown_block, failure_descriptions).

        Returns:
            Tuple of (attachment_markdown_block, failure_descriptions).
            attachment_markdown_block is empty string if no attachments were processed.
        """
        import base64
        from datetime import datetime

        attachment_parts: list[str] = []
        failures: list[str] = []

        for att in attachments:
            att_type = att.get("type", "unknown")
            file_name = att.get("fileName", "file")
            base64_data = att.get("base64Data")

            if not base64_data:
                continue

            now = datetime.now()
            date_folder = now.strftime("%Y-%m-%d")
            asset_dir = Path.home() / "Chat" / "assets" / date_folder
            asset_dir.mkdir(parents=True, exist_ok=True)

            timestamp = now.strftime("%H-%M-%S")
            ext = Path(file_name).suffix or ".bin"
            safe_name = Path(file_name).stem[:30]  # Truncate long names
            unique_name = f"{timestamp}_{safe_name}{ext}"
            file_path = asset_dir / unique_name

            try:
                file_bytes = base64.b64decode(base64_data)
                file_path.write_bytes(file_bytes)
                logger.info(f"Saved attachment: {file_path}")

                # Use vault-relative path for display (enables UI asset fetching)
                relative_path = f"Chat/assets/{date_folder}/{unique_name}"

                if att_type == "image":
                    # For images, use markdown image syntax with relative path
                    # Also include absolute path for Claude to read
                    attachment_parts.append(
                        f"![{file_name}]({relative_path})\n"
                        f"*(Absolute path for reading: {file_path})*"
                    )
                elif att_type in ("text", "code"):
                    # For text/code files, save to disk and reference by path
                    # Claude can use the Read tool to access the content
                    file_size_kb = len(file_bytes) / 1024
                    attachment_parts.append(
                        f"**[{file_name}]({relative_path})** ({file_size_kb:.1f} KB)\n"
                        f"*(Absolute path for reading: {file_path})*"
                    )
                elif att_type == "pdf":
                    attachment_parts.append(
                        f"**[{file_name}]({relative_path})**\n"
                        f"*(Absolute path for reading: {file_path})*"
                    )
                else:
                    attachment_parts.append(f"[{file_name}]({relative_path})")

            except Exception as e:
                logger.error(f"Failed to save attachment {file_name}: {e}")
                attachment_parts.append(f"[Failed to attach: {file_name}]")
                failures.append(f"{file_name}: {e}")

        return "\n\n".join(attachment_parts), failures

    async def _discover_capabilities(
        self,
        agent: Any,
        session: Any,
        trust_level: Optional[str],
    ) -> CapabilityBundle:
        """Discover and filter all capabilities (MCPs, skills, plugins, trust level).

        Handles MCP loading, skill/plugin discovery, trust resolution, and
        capability filtering.  Warning events are returned in the bundle's
        ``warnings`` list so the caller can yield them at the appropriate time.

        Returns:
            CapabilityBundle with all resolved capabilities and any warnings.
        """
        from parachute.core.trust import normalize_trust_level

        warnings: list[dict] = []

        # --- MCP loading -------------------------------------------------
        resolved_mcps = None
        mcp_warnings: list[str] = []
        mcp_load_warning: WarningEvent | None = None
        try:
            global_mcps = await load_mcp_servers(Path.home())
            resolved_mcps = resolve_mcp_servers(agent.mcp_servers, global_mcps)

            if resolved_mcps:
                resolved_mcps, mcp_warnings = validate_and_filter_servers(resolved_mcps)
                if mcp_warnings:
                    logger.warning(
                        f"MCP configuration issues (continuing with valid servers): "
                        f"{'; '.join(mcp_warnings[:3])}"
                        f"{'...' if len(mcp_warnings) > 3 else ''}"
                    )
        except Exception as e:
            logger.error(f"Failed to load MCP servers (continuing without MCP): {e}")
            resolved_mcps = None
            mcp_load_warning = WarningEvent(
                code=ErrorCode.MCP_LOAD_FAILED,
                title="MCP Tools Unavailable",
                message="MCP servers failed to load. Chat will continue without MCP tools.",
                details=[str(e)],
                session_id=session.id if session.id != "pending" else None,
            )

        # --- Plugin directory resolution -----------------------------------
        # Skills in .claude/skills/ and agents in .claude/agents/ are discovered
        # natively by the SDK via setting_sources=["project"]. No manual discovery needed.
        settings = get_settings()
        plugin_dirs: list[Path] = []

        # Load additional configured plugin directories (from settings.plugin_dirs)
        for dir_str in settings.plugin_dirs:
            plugin_path = Path(dir_str).expanduser().resolve()
            if plugin_path.is_dir():
                plugin_dirs.append(plugin_path)
                logger.info(f"Loaded configured plugin: {plugin_path}")
            else:
                logger.warning(f"Plugin directory not found, skipping: {plugin_path}")

        # Custom agents: SDK discovers .claude/agents/ natively
        agents_dict = None

        # --- Trust level resolution ---------------------------------------
        # Priority: client param > session stored > direct (default)
        logger.info(
            f"Trust resolution: client={trust_level}, session.trust_level={session.trust_level}"
        )
        if trust_level:
            try:
                session_trust = TrustLevel(normalize_trust_level(trust_level))
                logger.info(
                    f"Using client trust: {trust_level} -> {session_trust.value}"
                )
            except ValueError:
                logger.warning(f"Invalid trust_level from client: {trust_level}")
                session_trust = session.get_trust_level()
        elif session.trust_level:
            session_trust = session.get_trust_level()
        else:
            session_trust = TrustLevel.DIRECT

        effective_trust = session_trust.value

        # --- Stage 1: Trust-level capability filtering --------------------
        if resolved_mcps:
            pre_count = len(resolved_mcps)
            resolved_mcps = filter_by_trust_level(resolved_mcps, effective_trust)
            if len(resolved_mcps) < pre_count:
                logger.info(
                    f"Trust filter ({effective_trust}): "
                    f"{pre_count} → {len(resolved_mcps)} MCPs"
                )

        # --- Inject session context into MCP server env vars --------------
        if resolved_mcps:
            trust_level_str = effective_trust
            for mcp_name, mcp_config in resolved_mcps.items():
                env = {**mcp_config.get("env", {})}
                env["PARACHUTE_SESSION_ID"] = session.id
                env["PARACHUTE_TRUST_LEVEL"] = trust_level_str
                env["PARACHUTE_PROJECT_ID"] = session.project_id or ""
                resolved_mcps[mcp_name] = {**mcp_config, "env": env}
            logger.info(
                f"Injected session context into {len(resolved_mcps)} MCP servers"
            )

        # --- Collect warning events to yield after PromptMetadataEvent ---
        if mcp_load_warning:
            warnings.append(mcp_load_warning.model_dump(by_alias=True))
        if mcp_warnings:
            warnings.append(
                WarningEvent(
                    code=ErrorCode.MCP_CONNECTION_FAILED,
                    title="MCP Configuration Issues",
                    message=f"{len(mcp_warnings)} MCP server(s) skipped due to configuration issues.",
                    details=mcp_warnings[:5],
                    session_id=session.id if session.id != "pending" else None,
                ).model_dump(by_alias=True)
            )

        return CapabilityBundle(
            resolved_mcps=resolved_mcps,
            plugin_dirs=plugin_dirs,
            agents_dict=agents_dict,
            effective_trust=effective_trust,
            warnings=warnings,
        )

    async def _run_trusted(
        self,
        session: Any,
        caps: CapabilityBundle,
        actual_message: str,
        effective_prompt: str,
        is_full_prompt: bool,
        effective_cwd: Path,
        resume_id: Optional[str],
        model: Optional[str],
        claude_token: Optional[str],
        message_queue: asyncio.Queue,
        interrupt: Any,
        permission_handler: Any,
        permission_denials: list[dict[str, Any]],
        is_new: bool,
        message: str,
        working_directory: Optional[str],
        agent_type: Optional[str],
        resume_info: Any,
        start_time: float,
        mode: str = "converse",
    ) -> AsyncGenerator[dict, None]:
        """Run the trusted (direct/bare-metal) execution path.

        Async generator that yields all SSE events for the trusted path,
        including session finalization, bridge observation, and the DoneEvent.
        Handles its own CancelledError and Exception cases by yielding the
        appropriate error events, so callers can treat the generator as safe.
        """
        result_text = ""
        text_blocks: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        captured_session_id: Optional[str] = None
        captured_model: Optional[str] = None
        session_finalized = False
        current_text = ""
        inject_count = 0
        initial_user_echo_seen = False

        sdk_can_use_tool = permission_handler.create_sdk_callback()

        logger.info(
            f"SDK launch: cwd={effective_cwd}, resume={resume_id}, "
            f"is_new={is_new}, session={session.id[:8] if session.id else None}"
        )

        try:
            async for event in query_streaming(
                prompt=actual_message,
                system_prompt=effective_prompt if is_full_prompt else None,
                system_prompt_append=effective_prompt
                if not is_full_prompt and effective_prompt
                else None,
                use_claude_code_preset=not is_full_prompt,
                setting_sources=["project"],
                cwd=effective_cwd,
                resume=resume_id,
                tools=None,
                mcp_servers=caps.resolved_mcps,
                permission_mode="default",
                can_use_tool=sdk_can_use_tool,
                plugin_dirs=caps.plugin_dirs if caps.plugin_dirs else None,
                agents=caps.agents_dict,
                claude_token=claude_token,
                message_queue=message_queue,
                **(
                    {"model": model or self.settings.default_model}
                    if (model or self.settings.default_model)
                    else {}
                ),
            ):
                if interrupt.is_interrupted:
                    break

                event_type = event.get("type")
                logger.debug(f"SDK Event: type={event_type} keys={list(event.keys())}")

                # Capture session ID and immediately save to database
                if event.get("session_id"):
                    captured_session_id = event["session_id"]

                    if is_new and not session_finalized and captured_session_id:
                        title = (
                            generate_title_from_message(message)
                            if message.strip()
                            else None
                        )
                        _set_title_source(session, "default")
                        session = await self.session_manager.finalize_session(
                            session,
                            captured_session_id,
                            captured_model,
                            title=title,
                            agent_type=agent_type,
                            mode=mode,
                        )
                        session_finalized = True
                        logger.info(
                            f"Early finalized session: {captured_session_id[:8]}..."
                        )

                        # Update permission handler with finalized session
                        permission_handler.session = session
                        self.pending_permissions.pop("pending", None)
                        self.pending_permissions[captured_session_id] = (
                            permission_handler
                        )

                        # Second session event now that we have the real ID
                        yield SessionEvent(
                            session_id=captured_session_id,
                            working_directory=working_directory,
                            resume_info=resume_info.model_dump(),
                            trust_level=caps.effective_trust,
                        ).model_dump(by_alias=True)

                # Handle different event types
                if event_type == "system" and event.get("subtype") == "init":
                    yield InitEvent(
                        tools=event.get("tools", []),
                        permission_mode=event.get("permissionMode"),
                    ).model_dump(by_alias=True)

                elif event_type == "assistant":
                    message_content = event.get("message", {})
                    content_blocks = message_content.get("content", [])

                    if not captured_model and message_content.get("model"):
                        captured_model = message_content["model"]
                        yield ModelEvent(model=captured_model).model_dump(by_alias=True)

                    for block in content_blocks:
                        block_type = block.get("type")

                        if block_type == "thinking":
                            yield ThinkingEvent(
                                content=block.get("thinking", "")
                            ).model_dump(by_alias=True)

                        elif block_type == "text":
                            new_text = block.get("text", "")
                            if new_text != current_text:
                                delta = new_text[len(current_text) :]
                                yield TextEvent(
                                    content=new_text,
                                    delta=delta,
                                ).model_dump(by_alias=True)
                                current_text = new_text
                                if not text_blocks or text_blocks[-1] != new_text:
                                    if text_blocks:
                                        text_blocks[-1] = new_text
                                    else:
                                        text_blocks.append(new_text)
                                result_text = "\n\n".join(text_blocks)

                        elif block_type == "tool_use":
                            tool_call = {
                                "id": block.get("id"),
                                "name": block.get("name"),
                                "input": block.get("input"),
                            }
                            tool_calls.append(tool_call)
                            yield ToolUseEvent(tool=tool_call).model_dump(by_alias=True)

                            # Emit user_question event for AskUserQuestion
                            if block.get("name") == "AskUserQuestion":
                                questions = block.get("input", {}).get("questions", [])
                                if questions and captured_session_id:
                                    tool_use_id = block.get("id", "")
                                    request_id = (
                                        f"{captured_session_id}-q-{tool_use_id}"
                                    )
                                    permission_handler.next_question_tool_use_id = (
                                        tool_use_id
                                    )
                                    yield UserQuestionEvent(
                                        request_id=request_id,
                                        session_id=captured_session_id,
                                        questions=questions,
                                    ).model_dump(by_alias=True)
                                    logger.info(
                                        f"Emitted user_question event: {request_id}"
                                    )

                            current_text = ""

                elif event_type == "user":
                    msg_content = event.get("message", {}).get("content", "")
                    if isinstance(msg_content, str) and msg_content:
                        if not initial_user_echo_seen:
                            initial_user_echo_seen = True
                        else:
                            inject_count += 1
                            yield UserMessageEvent(
                                content=msg_content,
                            ).model_dump(by_alias=True)
                    else:
                        for block in (
                            msg_content if isinstance(msg_content, list) else []
                        ):
                            if block.get("type") == "tool_result":
                                content = block.get("content", "")
                                if isinstance(content, list):
                                    content = "\n".join(
                                        c.get("text", str(c)) for c in content
                                    )
                                yield ToolResultEvent(
                                    tool_use_id=block.get("tool_use_id", ""),
                                    content=str(content),
                                    is_error=block.get("is_error", False),
                                ).model_dump(by_alias=True)

                elif event_type == "result":
                    if event.get("result"):
                        result_text = event["result"]
                        yield TextEvent(
                            content=result_text,
                            delta=result_text[len(current_text) :],
                        ).model_dump(by_alias=True)
                    if event.get("session_id"):
                        captured_session_id = event["session_id"]

                elif event_type == "error":
                    error_msg = event.get("error", "Unknown SDK error")
                    logger.error(f"SDK error event received: {error_msg}")

                    error_lower = error_msg.lower()
                    is_session_issue = (
                        "not found" in error_lower
                        or "does not exist" in error_lower
                        or "enoent" in error_lower
                    )

                    if is_session_issue:
                        yield SessionUnavailableEvent(
                            reason="sdk_error",
                            session_id=session.id,
                            has_markdown_history=False,
                            message_count=session.message_count,
                            message=f"Session could not be loaded: {error_msg}",
                        ).model_dump(by_alias=True)
                    else:
                        typed = parse_error(error_msg)
                        yield TypedErrorEvent.from_typed_error(
                            typed, session_id=captured_session_id or session.id
                        ).model_dump(by_alias=True)

                    return

            # Finalize session (if not already done early)
            if is_new and captured_session_id and not session_finalized:
                title = (
                    generate_title_from_message(message) if message.strip() else None
                )
                _set_title_source(session, "default")
                session = await self.session_manager.finalize_session(
                    session,
                    captured_session_id,
                    captured_model,
                    title=title,
                    agent_type=agent_type,
                    mode=mode,
                )
                session_finalized = True
                logger.info(f"Finalized session: {captured_session_id[:8]}...")

            # Update message count
            final_session_id = captured_session_id or session.id
            if final_session_id and final_session_id != "pending":
                await self.session_manager.increment_message_count(
                    final_session_id, 2 + inject_count
                )

            # Bridge agent post-turn observe (fire-and-forget)
            if (
                final_session_id
                and final_session_id != "pending"
                and message
                and result_text
            ):
                from parachute.core.bridge_agent import observe as bridge_observe

                exchange_number = session.message_count // 2 + 1
                session_metadata = session.metadata or {}
                _bridge_task = asyncio.create_task(
                    bridge_observe(
                        session_id=final_session_id,
                        message=message,
                        result_text=result_text,
                        tool_calls=tool_calls or [],
                        exchange_number=exchange_number,
                        session_title=session.title,
                        title_source=session_metadata.get("title_source"),
                        session_store=self.session_store,
                        vault_path=Path.home(),
                        claude_token=self.settings.claude_code_oauth_token,
                    )
                )
                _bridge_task.add_done_callback(
                    lambda t: logger.warning(f"bridge_observe error: {t.exception()}")
                    if not t.cancelled() and t.exception()
                    else None
                )

            duration_ms = int((time.time() - start_time) * 1000)
            yield DoneEvent(
                response=result_text,
                session_id=captured_session_id or session.id,
                working_directory=working_directory,
                message_count=session.message_count + 2 + inject_count,
                model=captured_model,
                duration_ms=duration_ms,
                tool_calls=tool_calls if tool_calls else None,
                permission_denials=permission_denials if permission_denials else None,
                session_resume=resume_info.model_dump(),
            ).model_dump(by_alias=True)

        except asyncio.CancelledError:
            yield AbortedEvent(
                message="Stream cancelled",
                session_id=captured_session_id or session.id,
                partial_response=result_text if result_text else None,
            ).model_dump(by_alias=True)
            raise

        except Exception as e:
            logger.error(f"Streaming error: {e}", exc_info=True)
            if "ENOENT" in str(e) or "not found" in str(e).lower():
                yield SessionUnavailableEvent(
                    reason="sdk_session_not_found",
                    session_id=session.id,
                    has_markdown_history=False,
                    message_count=0,
                    message="The conversation history could not be loaded.",
                ).model_dump(by_alias=True)
            else:
                typed = parse_error(e)
                yield TypedErrorEvent.from_typed_error(
                    typed, session_id=captured_session_id or session.id
                ).model_dump(by_alias=True)

    async def _process_sandbox_event(
        self,
        event: dict,
        ctx: _SandboxCallContext,
    ) -> AsyncGenerator[dict, None]:
        """Process a single sandbox event — shared by primary and retry streams."""
        event_type = event.get("type", "")
        if event_type == "error":
            sandbox_err = event.get("error") or "Unknown sandbox error"
            logger.error(f"Sandbox error: {sandbox_err}")
            yield ErrorEvent(
                error=f"Sandbox: {sandbox_err}",
            ).model_dump(by_alias=True)
            return

        # Rewrite session IDs to our canonical sandbox_sid
        if event_type in ("session", "done") and "sessionId" in event:
            event = {
                **event,
                "sessionId": ctx.sandbox_sid,
                "trustLevel": ctx.effective_trust,
            }
        if event_type == "text":
            ctx.sbx["had_text"] = True
            ctx.sbx["response_text"] = event.get("content", ctx.sbx["response_text"])

        # Finalize BEFORE yielding "done" to prevent race condition
        if event_type == "done":
            if ctx.is_new and not ctx.sbx["finalized"]:
                try:
                    title = (
                        generate_title_from_message(ctx.sbx["message"])
                        if ctx.sbx["message"].strip()
                        else None
                    )
                    _set_title_source(ctx.sbx["session"], "default")
                    ctx.sbx["session"] = await self.session_manager.finalize_session(
                        ctx.sbx["session"],
                        ctx.sandbox_sid,
                        ctx.captured_model,
                        title=title,
                        agent_type=ctx.agent_type,
                        mode=ctx.mode,
                    )
                    ctx.sbx["finalized"] = True
                    logger.info(
                        f"Finalized sandbox session: {ctx.sandbox_sid[:8]} "
                        f"trust={ctx.effective_trust}"
                    )
                except Exception as e:
                    logger.error(
                        f"Failed to finalize sandbox session {ctx.sandbox_sid[:8]}: {e}"
                    )

            # Write synthetic transcript (fallback for host-side session search/list)
            if ctx.sbx["had_text"]:
                self.session_manager.write_sandbox_transcript(
                    ctx.sandbox_sid,
                    ctx.sbx["message"],
                    ctx.sbx["response_text"],
                    working_directory=ctx.effective_working_dir,
                )

        yield event

    async def _run_sandboxed(
        self,
        session: Any,
        caps: CapabilityBundle,
        actual_message: str,
        effective_prompt: str,
        is_full_prompt: bool,
        effective_working_dir: Optional[str],
        is_new: bool,
        model: Optional[str],
        message: str,
        agent_type: Optional[str],
        captured_model: Optional[str],
        mode: str = "converse",
    ) -> AsyncGenerator[dict, None]:
        """Run the sandboxed (Docker container) execution path.

        Async generator that yields all SSE events for the sandboxed path.
        Called by ``run_streaming()`` only after confirming Docker is available.
        """
        # Use a real session ID — "pending" would cause SDK inside the container
        # to try resuming a nonexistent session
        sandbox_sid = session.id if session.id != "pending" else str(uuid.uuid4())

        # Convert working directory to container path (/home/sandbox/Parachute/...)
        sandbox_wd = None
        if effective_working_dir:
            wd = str(effective_working_dir)
            if wd.startswith("/home/sandbox/Parachute/"):
                sandbox_wd = wd
            elif wd.startswith("/vault/"):
                sandbox_wd = f"/home/sandbox/Parachute/{wd[len('/vault/') :]}"
            elif wd.startswith(str(Path.home())):
                relative = wd[len(str(Path.home())) :].lstrip("/")
                sandbox_wd = f"/home/sandbox/Parachute/{relative}"
            else:
                sandbox_wd = f"/home/sandbox/Parachute/{wd.lstrip('/')}"

        sandbox_paths = list(session.permissions.allowed_paths)
        if sandbox_wd and sandbox_wd not in sandbox_paths:
            sandbox_paths.append(sandbox_wd)

        logger.info(
            f"Running sandboxed execution for session {sandbox_sid[:8]} "
            f"wd={sandbox_wd} paths={sandbox_paths}"
        )

        sandbox_model = model or self.settings.default_model
        sandbox_system_prompt = (
            effective_prompt if not is_full_prompt and effective_prompt else None
        )

        sandbox_config = AgentSandboxConfig(
            session_id=sandbox_sid,
            agent_type=agent_type or "chat",
            allowed_paths=sandbox_paths,
            network_enabled=True,
            mcp_servers=caps.resolved_mcps,
            plugin_dirs=caps.plugin_dirs,
            agents=caps.agents_dict,
            working_directory=sandbox_wd,
            model=sandbox_model,
            system_prompt=sandbox_system_prompt,
            session_source=session.source,
        )

        # Three-tier resume strategy: SDK resume → history injection → fresh start
        sandbox_message = actual_message
        resume_session_id: str | None = None
        if not is_new:
            resume_session_id = sandbox_sid
            if resume_session_id:
                logger.info(
                    f"Will resume sandbox session {sandbox_sid[:8]} from SDK transcript"
                )

        if not resume_session_id and not is_new:
            prior_messages = await self.session_manager._load_sdk_messages(session)
            if prior_messages:
                history_lines = []
                for msg in prior_messages:
                    role = msg["role"].upper()
                    history_lines.append(f"[{role}]: {msg['content']}")
                history_block = "\n".join(history_lines)
                sandbox_message = (
                    f"<conversation_history>\n{history_block}\n"
                    f"</conversation_history>\n\n{actual_message}"
                )
                logger.info(
                    f"Injected {len(prior_messages)} prior messages "
                    f"into sandbox prompt for session {sandbox_sid[:8]}"
                )

        # Ensure every sandboxed session has a project record
        if not session.project_id:
            auto_slug = str(uuid.uuid4()).replace("-", "")[:12]
            await self.session_store.create_project(
                slug=auto_slug,
                display_name=f"Session {sandbox_sid[:8]}",
            )
            await self.session_store.update_session(
                session.id,
                SessionUpdate(project_id=auto_slug),
            )
            session.project_id = auto_slug
            logger.info(
                f"Auto-created project {auto_slug} for session {sandbox_sid[:8]}"
            )

        # Pre-check sandbox image
        if not await self._sandbox.image_exists():
            from parachute.core.sandbox import SANDBOX_IMAGE

            logger.error(f"Sandbox image '{SANDBOX_IMAGE}' not built")
            yield ErrorEvent(
                error=f"Sandbox image '{SANDBOX_IMAGE}' not found. "
                "Build it from Settings or run: parachute doctor (for instructions).",
            ).model_dump(by_alias=True)
            return

        sandbox_stream = self._sandbox.run_session(
            session_id=sandbox_sid,
            config=sandbox_config,
            message=sandbox_message,
            resume_session_id=resume_session_id,
            project_slug=session.project_id,
        )

        sbx = {
            "had_text": False,
            "response_text": "",
            "finalized": False,
            "session": session,
            "message": message,
        }
        ctx = _SandboxCallContext(
            sbx=sbx,
            sandbox_sid=sandbox_sid,
            effective_trust=caps.effective_trust,
            is_new=is_new,
            captured_model=captured_model,
            agent_type=agent_type,
            effective_working_dir=effective_working_dir,
            mode=mode,
        )

        # Process sandbox events; retry with history injection if resume fails
        retry_with_history = False
        async for event in sandbox_stream:
            event_type = event.get("type", "")
            if event_type == "resume_failed":
                logger.warning(
                    f"SDK resume failed for {sandbox_sid[:8]}: "
                    f"{event.get('error', 'unknown')}, "
                    f"will retry with history injection"
                )
                retry_with_history = True
            elif event_type == "done" and retry_with_history:
                pass  # Suppress done from failed resume stream
            else:
                async for yielded in self._process_sandbox_event(event, ctx):
                    yield yielded

        if retry_with_history:
            retry_message = actual_message
            prior_messages = await self.session_manager._load_sdk_messages(
                sbx["session"]
            )
            if prior_messages:
                history_lines = []
                for msg in prior_messages:
                    role = msg["role"].upper()
                    history_lines.append(f"[{role}]: {msg['content']}")
                history_block = "\n".join(history_lines)
                retry_message = (
                    f"<conversation_history>\n{history_block}\n"
                    f"</conversation_history>\n\n{actual_message}"
                )
            retry_stream = self._sandbox.run_session(
                session_id=sandbox_sid,
                config=sandbox_config,
                message=retry_message,
                project_slug=session.project_id,
            )
            async for event in retry_stream:
                async for yielded in self._process_sandbox_event(event, ctx):
                    yield yielded

        session = sbx["session"]

        if not sbx["had_text"]:
            logger.warning("Sandbox produced no text output")

        # Increment message count for sandbox sessions
        if sbx["had_text"] and sandbox_sid:
            try:
                await self.session_manager.increment_message_count(sandbox_sid, 2)
            except Exception as e:
                logger.warning(
                    f"Failed to increment message count for {sandbox_sid[:8]}: {e}"
                )

    async def abort_stream(self, session_id: str) -> bool:
        """Abort an active streaming session."""
        interrupt = self.active_streams.get(session_id)
        if interrupt:
            logger.info(f"Aborting stream: {session_id[:8]}...")
            interrupt.interrupt()
            return True
        return False

    def inject_message(self, session_id: str, message: str) -> InjectResult:
        """Inject a user message into an active stream."""
        queue = self.active_stream_queues.get(session_id)
        if queue is None:
            return InjectResult.NO_STREAM
        try:
            queue.put_nowait(message)
            logger.info(f"Injected message into stream: {session_id[:8]}...")
            return InjectResult.OK
        except asyncio.QueueFull:
            return InjectResult.QUEUE_FULL

    def has_active_stream(self, session_id: str) -> bool:
        """Check if a session has an active stream."""
        return session_id in self.active_streams

    def get_active_stream_ids(self) -> list[str]:
        """Get all session IDs with active streams."""
        return list(self.active_streams.keys())

    # =========================================================================
    # Permission Management
    # =========================================================================

    def grant_permission(
        self, session_id: str, request_id: str, pattern: Optional[str] = None
    ) -> bool:
        """
        Grant a pending permission request.

        Args:
            session_id: The session ID
            request_id: The permission request ID
            pattern: Optional glob pattern for the grant (e.g., "Blogs/**/*")

        Returns:
            True if granted successfully
        """
        handler = self.pending_permissions.get(session_id)
        if handler:
            return handler.grant(request_id, pattern)
        return False

    def deny_permission(self, session_id: str, request_id: str) -> bool:
        """
        Deny a pending permission request.

        Args:
            session_id: The session ID
            request_id: The permission request ID

        Returns:
            True if denied successfully
        """
        handler = self.pending_permissions.get(session_id)
        if handler:
            return handler.deny(request_id)
        return False

    def get_pending_permissions(self, session_id: str) -> list[dict]:
        """
        Get pending permission requests for a session.

        Args:
            session_id: The session ID

        Returns:
            List of pending permission request dictionaries
        """
        handler = self.pending_permissions.get(session_id)
        if handler:
            return [
                {
                    "id": r.id,
                    "tool_name": r.tool_name,
                    "file_path": r.file_path,
                    "timestamp": r.timestamp.isoformat(),
                }
                for r in handler.get_pending()
            ]
        return []

    async def _build_system_prompt(
        self,
        agent: AgentDefinition,
        custom_prompt: Optional[str] = None,
        contexts: Optional[list[str]] = None,
        prior_conversation: Optional[str] = None,
        working_directory: Optional[str] = None,
        credential_keys: Optional[set[str]] = None,
        mode: str = "converse",
        project_memory: Optional[str] = None,
    ) -> tuple[str, dict[str, Any]]:
        """
        Build the system prompt additions.

        The SDK handles project-level discovery (CLAUDE.md, .claude/ commands/skills/agents)
        via setting_sources=["project"]. This method builds additional content:
        - Vault-level CLAUDE.md (outside the project root)
        - Prior conversation history (runtime only)
        - Explicitly selected context files

        For converse mode: returns CONVERSE_PROMPT as a full replacement (no preset).
        For cocreate mode: returns COCREATE_PROMPT_APPEND appended to Claude Code preset.

        Returns:
            Tuple of (prompt_string, metadata_dict) for transparency
        """
        # Track metadata for transparency
        metadata: dict[str, Any] = {
            "prompt_source": "converse" if mode == "converse" else "claude_code_preset",
            "prompt_source_path": None,
            "context_files": [],
            "context_tokens": 0,
            "context_truncated": False,
            "agent_name": agent.name,
            "available_agents": [],
            "base_prompt_tokens": 0,  # SDK handles base prompt
            "working_directory_claude_md": None,
        }

        # Build append content (runtime-only additions)
        append_parts: list[str] = []

        # Handle custom prompt - if provided, this REPLACES everything
        # (useful for specialized agents that don't want Claude Code preset)
        if custom_prompt:
            metadata["prompt_source"] = "custom"
            metadata["total_prompt_tokens"] = len(custom_prompt) // 4
            # For custom prompts, we return the full custom prompt
            # The caller should use system_prompt instead of system_prompt_append
            return custom_prompt, metadata

        # Handle non-vault agents with their own prompts
        if agent.system_prompt and agent.name != "vault-agent":
            metadata["prompt_source"] = "agent"
            metadata["prompt_source_path"] = agent.path
            metadata["total_prompt_tokens"] = len(agent.system_prompt) // 4
            # Agent has custom prompt - return it for full override
            return agent.system_prompt, metadata

        # Converse mode: full replacement prompt (no Claude Code preset)
        # Cocreate mode: append to Claude Code preset
        if mode == "converse":
            append_parts.append(CONVERSE_PROMPT)
        else:
            # Cocreate: start with our append framing, then add vault CLAUDE.md below
            append_parts.append(COCREATE_PROMPT_APPEND)
            # SDK handles project-level CLAUDE.md via setting_sources=["project"].
            # We only load vault-level CLAUDE.md here (outside the project root).
            vault_claude = Path.home() / "CLAUDE.md"
            if vault_claude.exists():
                try:
                    content = (await asyncio.to_thread(vault_claude.read_text)).strip()
                    if content:
                        append_parts.append(content)
                        metadata["claude_md_loaded"] = True
                        metadata["prompt_source_path"] = "CLAUDE.md"
                except OSError as e:
                    logger.warning(f"Failed to read vault CLAUDE.md: {e}")

        # Project context (core_memory from Project node) — injected after mode framing
        if project_memory:
            append_parts.append(f"## Project Context\n\n{project_memory}")

        # Working directory framing — tell the AI where it's operating
        # (SDK loads the actual CLAUDE.md via setting_sources=["project"] + cwd)
        if working_directory:
            wd_path = Path(working_directory)
            if not wd_path.is_absolute():
                wd_path = Path.home() / working_directory
            try:
                display_path = str(wd_path.relative_to(Path.home()))
            except ValueError:
                # Outside home — use leaf name only, never expose absolute paths
                display_path = wd_path.name

            append_parts.append(
                f"## Working Directory\n\n"
                f"You are operating in: `{display_path}/` "
                f"(within the Parachute vault)\n"
                f"File operations, code changes, and commands execute here by default."
            )

        # Handle explicitly selected context files (beyond automatic hierarchy)
        # These are files the user explicitly selected in the UI
        if contexts:
            context_folder_service = ContextFolderService(Path.home())

            # Separate folder paths from file paths
            folder_paths: list[str] = []
            file_paths: list[str] = []

            for ctx in contexts:
                # .md entries are individual files → loaded by context_loader (lib/)
                # everything else is a folder path → walked by context_folders (core/)
                if ctx.endswith(".md"):
                    file_paths.append(ctx)
                else:
                    folder_paths.append(ctx)

            # Load folder-based context (explicit selections only)
            if folder_paths:
                try:
                    chain = context_folder_service.build_chain(
                        folder_paths, max_tokens=40000
                    )
                    if chain.files:
                        folder_context = context_folder_service.format_chain_for_prompt(
                            chain, working_directory=working_directory
                        )
                        append_parts.append(folder_context)
                        metadata["context_files"].extend(chain.file_paths)
                        metadata["context_tokens"] += chain.total_tokens
                        metadata["context_truncated"] = chain.truncated
                        logger.info(
                            f"Loaded {len(chain.files)} explicit context files ({chain.total_tokens} tokens)"
                        )
                except Exception as e:
                    logger.warning(f"Failed to load folder context: {e}")

            # Load legacy file-based context
            if file_paths:
                try:
                    context_result = await load_agent_context(
                        {"include": file_paths, "max_tokens": 10000},
                        Path.home(),
                    )
                    if context_result.get("content"):
                        append_parts.append(format_context_for_prompt(context_result))
                        metadata["context_files"].extend(
                            context_result.get("files", [])
                        )
                        metadata["context_tokens"] += context_result.get(
                            "totalTokens", 0
                        )
                        metadata["context_truncated"] = metadata[
                            "context_truncated"
                        ] or context_result.get("truncated", False)
                except Exception as e:
                    logger.warning(f"Failed to load file context: {e}")

        # Note working directory CLAUDE.md for metadata
        if working_directory:
            working_dir_path = Path(working_directory)
            if not working_dir_path.is_absolute():
                working_dir_path = Path.home() / working_directory

            for md_name in ["AGENTS.md", "CLAUDE.md"]:
                md_path = working_dir_path / md_name
                if md_path.exists():
                    try:
                        relative_path = md_path.relative_to(Path.home())
                        metadata["working_directory_claude_md"] = str(relative_path)
                    except ValueError:
                        # Outside home — use leaf name only, never expose absolute paths
                        metadata["working_directory_claude_md"] = md_path.name
                    break

        # Prior conversation (MUST be runtime - can't be in static files)
        if prior_conversation:
            prior_section = f"""
## Prior Conversation (IMPORTANT)

**The user is continuing a previous conversation they had with you (or another AI assistant).**
The messages below are from that earlier session. Treat them as if they happened in THIS conversation.

<prior_conversation>
{prior_conversation}
</prior_conversation>

The user is now continuing this conversation with you. Respond naturally as if you remember the above exchange.
"""
            append_parts.append(prior_section)

        # Credential discoverability — tell the agent which CLI tools are pre-authenticated
        # so it can use them proactively without being explicitly asked.
        # credential_keys is pre-filtered at the call site (empty for bot sessions).
        cred_keys = credential_keys or set()
        if cred_keys:
            tools: list[str] = []
            if "GH_TOKEN" in cred_keys:
                tools.append("`gh` (GitHub CLI — pre-authenticated)")
            if "AWS_ACCESS_KEY_ID" in cred_keys:
                tools.append("`aws` (AWS CLI — pre-authenticated)")
            if "NODE_AUTH_TOKEN" in cred_keys:
                tools.append("`npm` (npm registry — pre-authenticated)")
            if tools:
                append_parts.append(
                    "## Authenticated CLI Tools\n\n"
                    + "\n".join(f"- {t}" for t in tools)
                )

        # Combine all append parts
        append_content = "\n\n".join(append_parts) if append_parts else ""

        # Calculate tokens for metadata
        metadata["total_prompt_tokens"] = len(append_content) // 4

        return append_content, metadata

    # =========================================================================
    # Session Management (delegated to SessionManager)
    # =========================================================================

    async def list_sessions(
        self,
        module: Optional[str] = None,
        archived: bool = False,
        search: Optional[str] = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """List all chat sessions."""
        sessions = await self.session_manager.list_sessions(
            module=module,
            archived=archived,
            search=search,
            limit=limit,
        )
        return [s.model_dump(by_alias=True) for s in sessions]

    async def get_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Get a session by ID with messages."""
        session = await self.session_manager.get_session_with_messages(session_id)
        if not session:
            return None

        return session.model_dump(by_alias=True)

    async def delete_session(self, session_id: str) -> bool:
        """Delete a session and clean up its container env if it was private."""
        session = await self.session_manager.get_session(session_id)
        project_id = session.project_id if session else None

        result = await self.session_manager.delete_session(session_id)

        if result and project_id:
            # Remove the container env if no other sessions reference it.
            # Atomic check-and-delete prevents double-remove when two sessions
            # sharing the same env are deleted concurrently.
            try:
                deleted = await self.session_store.delete_project_if_unreferenced(
                    project_id
                )
                if deleted:
                    await self._sandbox.delete_container(project_id)
                    logger.info(
                        f"Removed container env {project_id} with session {session_id[:8]}"
                    )
            except Exception as e:
                logger.warning(
                    f"Failed to clean up container env {project_id}: {e}"
                )

        return result

    async def archive_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Archive a session.

        The private container (if any) is left running so the session can be resumed
        if unarchived. reconcile() will eventually clean up containers for sessions
        that are no longer active.
        """
        archived = await self.session_manager.archive_session(session_id)
        if archived:
            return archived.model_dump(by_alias=True)
        return None

    async def unarchive_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Unarchive a session."""
        session = await self.session_manager.unarchive_session(session_id)
        if session:
            return session.model_dump(by_alias=True)
        return None

    async def get_session_stats(self) -> dict[str, Any]:
        """Get session statistics."""
        return await self.session_manager.get_stats()

    async def get_session_transcript(
        self,
        session_id: str,
        after_compact: bool = False,
        segment_index: Optional[int] = None,
        include_segment_metadata: bool = True,
    ) -> Optional[dict[str, Any]]:
        """
        Get the SDK transcript for a session with optional segmentation.

        Reads the JSONL file from ~/.claude/projects/ to get rich event history.

        Args:
            session_id: The session ID
            after_compact: If True, only return events after the last compact boundary
            segment_index: If provided, only return events for that segment
            include_segment_metadata: If True, include metadata about all segments

        Returns:
            Dictionary with events and optional segment metadata
        """
        import json
        from pathlib import Path

        # Look for SDK session file in two locations:
        # 1. ~/.claude/projects/ - primary location (real home)
        # 2. {vault}/.claude/projects/ - legacy from HOME override era

        session_file = None

        # Search in ~/.claude (primary location)
        home_projects_dir = Path.home() / ".claude" / "projects"
        if home_projects_dir.exists():
            for project_dir in home_projects_dir.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / f"{session_id}.jsonl"
                    if candidate.exists():
                        session_file = candidate
                        break

        # Fallback: search in ~/Parachute/.claude (legacy vault HOME override era)
        if not session_file:
            legacy_projects_dir = Path.home() / "Parachute" / ".claude" / "projects"
            if legacy_projects_dir.exists():
                for project_dir in legacy_projects_dir.iterdir():
                    if project_dir.is_dir():
                        candidate = project_dir / f"{session_id}.jsonl"
                        if candidate.exists():
                            session_file = candidate
                            logger.debug(
                                f"Found transcript in legacy vault location: {candidate}"
                            )
                            break

        if not session_file:
            return None

        # Parse the JSONL file and identify segments
        all_events: list[dict[str, Any]] = []
        model = None
        cwd = None

        try:
            with open(session_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        all_events.append(event)

                        # Extract metadata
                        if not model and event.get("model"):
                            model = event["model"]
                        if not cwd and event.get("cwd"):
                            cwd = event["cwd"]
                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            logger.error(f"Error reading transcript {session_id}: {e}")
            return None

        # Identify segments based on compact boundaries
        segments = self._identify_transcript_segments(all_events)

        # Determine which events to return
        if after_compact and segments:
            # Return only events from the last segment (after last compact)
            last_segment = segments[-1]
            events = all_events[last_segment["start_index"] : last_segment["end_index"]]
        elif segment_index is not None and 0 <= segment_index < len(segments):
            # Return events for a specific segment
            segment = segments[segment_index]
            events = all_events[segment["start_index"] : segment["end_index"]]
        else:
            # Return all events
            events = all_events

        result: dict[str, Any] = {
            "sessionId": session_id,
            "events": events,
            "model": model,
            "cwd": cwd,
            "eventCount": len(events),
            "totalEventCount": len(all_events),
        }

        if include_segment_metadata:
            # Build segment metadata (without full event data for unloaded segments)
            segment_metadata = []
            for i, seg in enumerate(segments):
                is_loaded = (
                    (not after_compact and segment_index is None)  # Full load
                    or (after_compact and i == len(segments) - 1)  # Last segment
                    or (segment_index == i)  # Specific segment
                )
                segment_metadata.append(
                    {
                        "index": i,
                        "isCompacted": seg["is_compacted"],
                        "messageCount": seg["message_count"],
                        "eventCount": seg["event_count"],
                        "startTime": seg["start_time"],
                        "endTime": seg["end_time"],
                        "preview": seg["preview"],
                        "loaded": is_loaded,
                    }
                )

            result["segments"] = segment_metadata
            result["segmentCount"] = len(segments)
            result["loadedSegmentIndex"] = (
                len(segments) - 1
                if after_compact
                else segment_index
                if segment_index is not None
                else None  # All loaded
            )

        return result

    def _identify_transcript_segments(
        self, events: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        """
        Identify segments in a transcript based on compact boundaries.

        A segment is a group of events between compact_boundary markers.
        The last segment (after the last compact) is the "current" segment.

        Returns list of segment metadata dictionaries.
        """
        segments: list[dict[str, Any]] = []
        current_start = 0
        current_messages = 0
        current_first_user_message = None
        current_start_time = None
        current_end_time = None

        for i, event in enumerate(events):
            event_type = event.get("type")
            subtype = event.get("subtype")
            timestamp = event.get("timestamp")

            # Track timestamps
            if timestamp:
                if current_start_time is None:
                    current_start_time = timestamp
                current_end_time = timestamp

            # Count user messages for message_count
            if event_type == "user":
                content = event.get("message", {}).get("content")
                # Only count actual user messages, not tool results
                if content and isinstance(content, (str, list)):
                    has_text = isinstance(content, str) or any(
                        block.get("type") == "text"
                        for block in content
                        if isinstance(block, dict)
                    )
                    if has_text:
                        current_messages += 1
                        if current_first_user_message is None:
                            current_first_user_message = self._extract_preview(event)

            # Check for compact boundary
            if event_type == "system" and subtype == "compact_boundary":
                # End current segment
                if current_start < i:
                    segments.append(
                        {
                            "start_index": current_start,
                            "end_index": i,  # Exclusive, doesn't include the boundary
                            "is_compacted": True,
                            "message_count": current_messages,
                            "event_count": i - current_start,
                            "start_time": current_start_time,
                            "end_time": current_end_time,
                            "preview": current_first_user_message or "",
                        }
                    )

                # Start new segment after the boundary
                current_start = i + 1
                current_messages = 0
                current_first_user_message = None
                current_start_time = None
                current_end_time = None

        # Add final segment (everything after last compact or all events if no compact)
        if current_start < len(events):
            segments.append(
                {
                    "start_index": current_start,
                    "end_index": len(events),
                    "is_compacted": False,  # Current segment, not yet compacted
                    "message_count": current_messages,
                    "event_count": len(events) - current_start,
                    "start_time": current_start_time,
                    "end_time": current_end_time,
                    "preview": current_first_user_message or "",
                }
            )

        return segments

    def _extract_preview(self, event: dict[str, Any], max_length: int = 100) -> str:
        """Extract a preview string from a user message event."""
        content = event.get("message", {}).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
            text = " ".join(text_parts)
        else:
            return ""

        # Clean and truncate
        text = " ".join(text.split())  # Normalize whitespace
        if len(text) > max_length:
            return text[: max_length - 3] + "..."
        return text

    # Note: Vault migration is now handled by the standalone script:
    # python -m scripts.migrate_vault --from /old/vault --to /new/vault
