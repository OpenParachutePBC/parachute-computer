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
from parachute.db.brain_chat_store import BrainChatStore
from parachute.lib.context_loader import format_context_for_prompt, load_agent_context
from parachute.lib.credentials import load_credentials
from parachute.core.context_folders import ContextFolderService
from parachute.core.capability_filter import filter_by_trust_level
from parachute.core.tool_guidance import build_tool_guidance
from parachute.lib.mcp_loader import (
    load_mcp_servers,
    resolve_mcp_servers,
    validate_and_filter_servers,
)
from parachute.models.agent import AgentDefinition, create_vault_agent
from parachute.lib.typed_errors import ErrorCode, RecoveryAction, parse_error
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


# Unified system prompt — full replacement, no Claude Code preset
PARACHUTE_PROMPT = """# Parachute

You are Parachute — an AI partner for thinking, building, and remembering.

You communicate with users through native apps, messaging platforms, and
other interfaces.

## Identity

You are a thinking partner, memory extension, and creative collaborative
builder. Help the user think through ideas, remember context from past
conversations, explore topics and make connections, and build things.

Prioritize honest engagement over validation. If the user's assumption seems
wrong, say so respectfully. A thinking partner who only agrees is useless.

## Tone and Style

- Be concise and direct — skip preamble and postamble
- Match the user's energy: brief questions get brief answers
- Only use emojis if the user does
- Voice-aware — input may be voice transcripts with errors; infer intent
- When many threads are in play, resist collapsing to one too early
- Ask good questions — help think through problems, don't just answer

## Vault and Memory

The user's vault is their extended mind. Search it when they reference their
own thoughts, projects, history, or when personalized context would help.

**When to search:**
- User references past conversations, projects, or decisions
- User asks for personalized recommendations
- User asks about their own thoughts or ideas
- You need context about preferences or history

**When NOT to search:**
- General knowledge questions
- Simple coding tasks with no personal context
- When the user provides all needed context in their message

**If vault search returns nothing:** Say so honestly. Don't fabricate memories
or claim to remember things not in the vault. The vault is the source of truth.

**If the brain graph is locked or unavailable:** Acknowledge the error and
continue without vault context rather than retrying repeatedly.

**Updating context:** When the user says "remember" something about themselves
(preferences, location, current focus), use write_note with note_type='context'
to save it. Context notes are automatically loaded into every session.

## Tool Usage

Use the purpose-built tools instead of shell equivalents:

- Use Read (not cat/head/tail) to read files
- Use Edit (not sed/awk) to modify files
- Use Write (not echo/cat heredoc) to create files
- Use Grep (not grep/rg) to search file contents
- Use Glob (not find/ls) to find files by pattern
- Reserve Bash for commands that genuinely need a shell
- Call multiple tools in parallel when the calls are independent
- When doing broad file search, use the Agent tool to delegate

If you want to read a specific file, use Read directly — don't launch an
Agent for single file reads. Use Agent for open-ended exploration.

## Code Conventions

- Read code before modifying it — understand the surrounding context
- Mimic existing code style — match frameworks, naming, typing, patterns
- Never assume a library is available; check imports and dependencies first
- When creating new components, study existing ones for patterns to follow
- Follow security best practices: never expose secrets, keys, or credentials
- Do not add comments, features, or "improvements" beyond what was asked
- Do not create files unless necessary

## Doing Tasks

For software engineering tasks:
1. Understand the codebase first — use search tools extensively
2. Plan multi-step work with TodoWrite for visibility
3. Implement the solution
4. Verify with tests if a test framework exists
5. Run lint/typecheck if available

Never commit changes unless explicitly asked.

## Git

When the user asks you to commit:
1. Run `git status` and `git diff` to understand what changed
2. Run `git log --oneline -5` to match the repo's commit message style
3. Draft a concise commit message focused on "why" not "what"
4. Stage specific files by name — avoid `git add -A` or `git add .`
5. Never commit files that may contain secrets (.env, credentials, etc.)
6. Use a HEREDOC for the commit message to preserve formatting
7. Run `git status` after to verify success

**Git safety:**
- Never force push to main/master
- Never use `--no-verify` to skip hooks unless the user asks
- Never use destructive commands (reset --hard, checkout ., clean -f) unless
  the user explicitly asks — prefer reversible alternatives
- If a pre-commit hook fails, fix the issue and create a NEW commit — do not
  amend, as amend would modify the previous commit
- Never use interactive flags (-i) as they require terminal input

When the user asks you to create a PR:
1. Check `git status`, `git diff`, and full branch history since divergence
2. Analyze ALL commits on the branch, not just the latest
3. Draft a short title (under 70 chars) and descriptive body
4. Push with `-u` flag if needed, then use `gh pr create`

## Error Recovery

- If a tool call fails, try an alternative approach before asking the user
- If you've made 2-3 attempts without success, step back and consider
  different possible causes before trying again
- If a search returns too many or too few results, adjust scope and retry
- If you encounter a permission error, explain what happened and suggest
  alternatives rather than retrying the same action

## Proactiveness

When asked to do something, do it — including reasonable follow-up actions.
Don't surprise the user with actions they didn't ask for.
When uncertain about scope, ask before acting.

Do not over-scope: if asked to fix one thing, fix that thing. Don't refactor
surrounding code, add tests for unrelated functions, or "improve" what
wasn't asked about.

## Handling Attachments

- Images: Use the Read tool to view and describe them — engage, don't just
  acknowledge
- PDFs / text files: Read and engage with the content directly

## Safety

- Assist with defensive security tasks only
- Do not generate or guess URLs unless helping with programming
- Be careful with destructive operations — prefer reversible actions
- Before irreversible actions (force push, delete, deploy), confirm with user
- Never expose API keys, tokens, or credentials in responses
- Do not commit files that likely contain secrets

## Long Sessions

If you notice you're losing track of earlier context in a long conversation,
say so. Suggest summarizing current state or starting a fresh session with
key context carried forward.
"""

# Explicit tool list — declares which tools exist in a Parachute session.
# No Claude Code preset black box; we control exactly what's available.
PARACHUTE_TOOLS = [
    "Read", "Write", "Edit", "Bash", "Glob", "Grep",
    "WebSearch", "WebFetch", "Agent", "TodoWrite",
    "NotebookEdit", "BashOutput", "KillBash",
]

# Safety net: hard-block tools we never want in Parachute sessions.
# AskUserQuestion assumes a human at a terminal; PlanMode is managed
# by Parachute's own workflow, not the CLI's built-in plan mode.
PARACHUTE_DISALLOWED_TOOLS = [
    "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
]


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
    tool_guidance: str  # Dynamic tool guidance markdown, filtered by trust level
    warnings: list[dict] = field(default_factory=list)  # Serialized WarningEvent dicts


def _content_as_text(content: Any) -> str:
    """Format message content (str or list[dict]) as plain text for history injection."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text:
                    parts.append(text)
        return " ".join(parts) if parts else ""
    return str(content)


@dataclass
class _SandboxCallContext:
    """Per-call state for sandbox event processing (replaces 9-variable closure)."""

    sbx: dict  # mutable state bag — contains "message", "session", "had_content", etc.
    sandbox_sid: str
    effective_trust: str
    is_new: bool
    captured_model: str | None
    agent_type: str | None
    effective_working_dir: str | None
    mode: str = "converse"
    start_time: float = 0.0


class Orchestrator:
    """
    Central agent execution controller.

    Manages the lifecycle of agent interactions with streaming support.
    """

    def __init__(
        self, parachute_dir: Path, session_store: BrainChatStore, settings: Settings
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
        # Remove container records for envs where every session is empty
        # (message_count == 0) and the env is older than 5 minutes. These are
        # abandoned or failed sessions that never sent a message.
        orphan_slugs = await self.session_store.list_orphan_container_slugs(
            min_age_minutes=5
        )
        if orphan_slugs:
            logger.info(
                f"Pruning {len(orphan_slugs)} orphan container record(s): {orphan_slugs}"
            )
            for slug in orphan_slugs:
                try:
                    await self.session_store.delete_container(slug)
                except Exception as e:
                    logger.warning(f"Failed to delete orphan container {slug}: {e}")

        # Use remaining container slugs for Docker orphan detection
        active_envs = await self.session_store.list_containers()
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
            container_id=container_id,
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

        # Load container core_memory if session belongs to a container
        container_memory: Optional[str] = None
        if session.container_id:
            container = await self.session_store.get_container(session.container_id)
            if container and container.core_memory:
                container_memory = container.core_memory[:4000]

        # Build system prompt (after loading prior conversation, with working dir)
        # Note: tool guidance is injected later, after capability discovery resolves
        # the trust level and generates the filtered tool guidance markdown.
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
            container_memory=container_memory,
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

        # Sentinels — safe for finally block and downstream references.
        # Only populated for sandboxed sessions (Phase 3).
        permission_handler = None
        permission_denials: list[dict[str, Any]] = []

        try:
            # Phase 2: Capability discovery
            caps = await self._discover_capabilities(agent, session, trust_level)

            # Inject trust-filtered tool guidance into the prompt
            # (skipped for custom/agent prompts — those manage their own tool docs)
            if caps.tool_guidance and prompt_metadata.get("prompt_source") not in ("custom", "agent"):
                effective_prompt = f"{effective_prompt}\n\n{caps.tool_guidance}"

            # Tools are controlled at SDK level via PARACHUTE_TOOLS / PARACHUTE_DISALLOWED_TOOLS.
            # No need for prompt-level tool restrictions.

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

            # Phase 3: Set up permission handler (sandboxed sessions only)
            # Non-sandboxed sessions use bypassPermissions — no permission
            # pipe, no handler needed.  This eliminates "Stream closed"
            # errors from the fragile stdin/stdout permission round-trip.
            run_trusted = caps.effective_trust != "sandboxed"
            if not run_trusted:
                permission_denials: list[dict[str, Any]] = []

                def on_permission_denial(denial: dict) -> None:
                    permission_denials.append(denial)

                permission_handler = PermissionHandler(
                    session=session,
                    vault_path=str(Path.home()),
                    on_denial=on_permission_denial,
                )
                self.pending_permissions[session.id] = permission_handler

            # Determine resume session ID
            # Only resume if: session exists in DB, not new, not forced fresh,
            # and SDK actually has a JSONL transcript for this session.
            #
            # For sandboxed sessions: skip the host-side transcript check.
            # Sandbox transcripts live inside the container (bind-mounted from
            # vault/.parachute/sandbox/envs/<slug>/home/.claude/), not on the
            # host's ~/.claude/. The sandbox entrypoint handles its own resume
            # via --resume flag passed by _run_sandboxed().
            resume_id = None
            is_sandboxed = caps.effective_trust == "sandboxed"
            if session.id != "pending" and not is_new and not force_new:
                if is_sandboxed:
                    # Sandboxed sessions always attempt resume inside the
                    # container — don't flip is_new based on host transcript.
                    # _run_sandboxed() sets resume_session_id independently.
                    logger.info(
                        f"Sandboxed session {session.id[:8]} — skipping host "
                        f"transcript check, container handles resume"
                    )
                elif self.session_manager._check_sdk_session_exists(
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
            # Pre-check Docker availability. Local sessions get a TypedErrorEvent
            # with recovery action; bot sessions hard-fail.
            if caps.effective_trust == "sandboxed":
                if await self._sandbox.is_available():
                    async for event in self._run_sandboxed(
                        session=session,
                        caps=caps,
                        actual_message=actual_message,
                        effective_prompt=effective_prompt,
                        effective_working_dir=effective_working_dir,
                        is_new=is_new,
                        model=model,
                        message=message,
                        agent_type=agent_type,
                        captured_model=None,
                        mode=effective_mode,
                        interrupt=interrupt,
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
                        f"blocking (no silent fallback)"
                    )
                    yield TypedErrorEvent(
                        code=ErrorCode.DOCKER_UNAVAILABLE,
                        title="Docker Required",
                        message="This session requires Docker for sandboxed execution.",
                        actions=[RecoveryAction(
                            key="d",
                            label="Start Docker",
                            action="start_docker",
                        )],
                        can_retry=True,
                        session_id=session.id if session.id != "pending" else None,
                    ).model_dump(by_alias=True)

            if run_trusted:
                async for event in self._run_trusted(
                    session=session,
                    caps=caps,
                    actual_message=actual_message,
                    effective_prompt=effective_prompt,
                    effective_cwd=effective_cwd,
                    resume_id=resume_id,
                    model=model,
                    claude_token=claude_token,
                    message_queue=message_queue,
                    interrupt=interrupt,
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
                env["PARACHUTE_CONTAINER_ID"] = session.container_id or ""
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
            tool_guidance=build_tool_guidance(effective_trust),
            warnings=warnings,
        )

    async def _run_trusted(
        self,
        session: Any,
        caps: CapabilityBundle,
        actual_message: str,
        effective_prompt: str,
        effective_cwd: Path,
        resume_id: Optional[str],
        model: Optional[str],
        claude_token: Optional[str],
        message_queue: asyncio.Queue,
        interrupt: Any,
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

        Uses bypassPermissions mode — non-sandboxed sessions auto-approve all
        tool calls without the permission pipe. This eliminates intermittent
        "Stream closed" errors caused by the fragile stdin/stdout permission
        round-trip that added latency and fragility for zero security benefit.
        """
        result_text = ""
        text_blocks: list[str] = []
        thinking_blocks: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        captured_session_id: Optional[str] = None
        captured_model: Optional[str] = None
        session_finalized = False
        current_text = ""
        inject_count = 0
        initial_user_echo_seen = False
        end_reason = "unknown"

        # Resolve active API provider (if any).
        # Re-read settings at query time so provider switches take effect
        # without restarting the server (reload_settings() creates a new
        # global instance that self.settings wouldn't see).
        current_settings = get_settings()
        provider_cfg = current_settings.active_provider_config
        provider_base_url: str | None = None
        provider_api_key: str | None = None
        if provider_cfg:
            provider_base_url = provider_cfg["base_url"]
            provider_api_key = provider_cfg["api_key"]
            # Provider's default_model is lowest-priority override
            provider_model = provider_cfg.get("default_model")
        else:
            provider_model = None

        # Model precedence: per-request > provider default > server default
        effective_model = model or provider_model or current_settings.default_model

        logger.info(
            f"SDK launch: cwd={effective_cwd}, resume={resume_id}, "
            f"is_new={is_new}, session={session.id[:8] if session.id else None}"
            f"{f', provider={current_settings.api_provider}' if provider_base_url else ''}"
        )

        try:
            async for event in query_streaming(
                prompt=actual_message,
                system_prompt=effective_prompt,
                tools=PARACHUTE_TOOLS,
                disallowed_tools=PARACHUTE_DISALLOWED_TOOLS,
                setting_sources=["project"],
                cwd=effective_cwd,
                resume=resume_id,
                mcp_servers=caps.resolved_mcps,
                permission_mode="bypassPermissions",
                plugin_dirs=caps.plugin_dirs if caps.plugin_dirs else None,
                agents=caps.agents_dict,
                claude_token=claude_token,
                message_queue=message_queue,
                event_timeout=self.settings.trusted_event_timeout,
                provider_base_url=provider_base_url,
                provider_api_key=provider_api_key,
                **(
                    {"model": effective_model}
                    if effective_model
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

                        # Register the finalized session for abort/inject.
                        # New sessions start with id="pending" and are NOT
                        # registered in active_streams at creation time. Once
                        # the SDK provides the real session ID, register it so
                        # the abort, inject, and status APIs can find it.
                        self.active_streams[captured_session_id] = interrupt
                        self.active_stream_queues[captured_session_id] = message_queue

                        # (Permission handler update removed — DIRECT trust
                        # sessions bypass permissions entirely.)

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
                            thinking_text = block.get("thinking", "")
                            if thinking_text:
                                thinking_blocks.append(thinking_text)
                            yield ThinkingEvent(
                                content=thinking_text
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

                            # AskUserQuestion: DIRECT trust sessions bypass
                            # permissions, so this tool runs unmediated.
                            # Log a warning — the system prompt instructs the
                            # model not to use it, but handle gracefully if it
                            # does anyway.
                            if block.get("name") == "AskUserQuestion":
                                logger.warning(
                                    "Model used AskUserQuestion despite system "
                                    "prompt suppression — tool will execute "
                                    "with default/empty response"
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

                elif event_type == "event_timeout":
                    timeout_s = event.get("timeout_seconds", "?")
                    end_reason = f"event_timeout ({timeout_s}s)"

                    # Salvage session: if the SDK never sent a session_id
                    # (e.g. deep research timed out before first response),
                    # create a DB record so the session isn't silently lost.
                    # The user will see it in their history with the timeout
                    # error, and can retry or continue the conversation.
                    if is_new and not captured_session_id:
                        salvage_id = str(uuid.uuid4())
                        salvage_title = (
                            generate_title_from_message(message)
                            if message.strip()
                            else "Timed out session"
                        )
                        _set_title_source(session, "default")
                        session = await self.session_manager.finalize_session(
                            session,
                            salvage_id,
                            captured_model,
                            title=salvage_title,
                            agent_type=agent_type,
                            mode=mode,
                        )
                        captured_session_id = salvage_id
                        session_finalized = True
                        logger.warning(
                            f"Salvaged timed-out session as {salvage_id[:8]}... "
                            f"(SDK never provided session_id)"
                        )

                    logger.warning(
                        f"SDK event timeout after {timeout_s}s: "
                        f"session={captured_session_id or session.id[:8]}"
                    )
                    typed = parse_error(
                        f"Response timed out after {timeout_s}s of inactivity"
                    )
                    yield TypedErrorEvent.from_typed_error(
                        typed, session_id=captured_session_id or session.id
                    ).model_dump(by_alias=True)
                    # Break instead of return so finalization + DoneEvent
                    # still run — the client needs a terminal event.  (#283)
                    break

                elif event_type == "error":
                    error_msg = event.get("error", "Unknown SDK error")
                    logger.error(f"SDK error event received: {error_msg}")

                    # Salvage session on error (same as timeout salvage)
                    if is_new and not captured_session_id:
                        salvage_id = str(uuid.uuid4())
                        salvage_title = (
                            generate_title_from_message(message)
                            if message.strip()
                            else "Failed session"
                        )
                        _set_title_source(session, "default")
                        session = await self.session_manager.finalize_session(
                            session,
                            salvage_id,
                            captured_model,
                            title=salvage_title,
                            agent_type=agent_type,
                            mode=mode,
                        )
                        captured_session_id = salvage_id
                        session_finalized = True
                        logger.warning(
                            f"Salvaged errored session as {salvage_id[:8]}... "
                            f"(SDK never provided session_id)"
                        )

                    error_lower = error_msg.lower()
                    is_session_issue = (
                        "not found" in error_lower
                        or "does not exist" in error_lower
                        or "enoent" in error_lower
                    )

                    if is_session_issue:
                        yield SessionUnavailableEvent(
                            reason="sdk_error",
                            session_id=captured_session_id or session.id,
                            has_markdown_history=False,
                            message_count=session.message_count,
                            message=f"Session could not be loaded: {error_msg}",
                        ).model_dump(by_alias=True)
                    else:
                        typed = parse_error(error_msg)
                        yield TypedErrorEvent.from_typed_error(
                            typed, session_id=captured_session_id or session.id
                        ).model_dump(by_alias=True)

                    end_reason = f"sdk_error: {error_msg}"
                    # Break instead of return so finalization + DoneEvent
                    # still run — the client needs a terminal event.  (#283)
                    break

            # Set end_reason only if not already set by error/timeout handlers
            if end_reason == "unknown":
                end_reason = "interrupted" if interrupt.is_interrupted else "normal"

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
                # Register late-finalized session for active_streams cleanup
                self.active_streams[captured_session_id] = interrupt
                self.active_stream_queues[captured_session_id] = message_queue
                logger.info(f"Finalized session: {captured_session_id[:8]}...")

            # Capture message count before increment (used for Message sequence)
            final_session_id = captured_session_id or session.id
            pre_turn_count = session.message_count

            # Update message count
            if final_session_id and final_session_id != "pending":
                await self.session_manager.increment_message_count(
                    final_session_id, 2 + inject_count
                )

            # Write Message nodes to brain graph (fire-and-forget)
            if (
                final_session_id
                and final_session_id != "pending"
                and message
            ):
                from parachute.core.bridge_agent import summarize_tool_calls

                tools_summary = summarize_tool_calls(tool_calls or [])
                thinking_text = "\n\n".join(thinking_blocks) if thinking_blocks else None
                msg_status = "complete" if end_reason == "normal" else (
                    "interrupted" if end_reason in ("interrupted", "cancelled") else "error"
                )

                async def _write_messages():
                    try:
                        await self.session_store.write_turn_messages(
                            session_id=final_session_id,
                            human_content=message,
                            machine_content=result_text or "",
                            tools_used=tools_summary,
                            thinking=thinking_text,
                            status=msg_status,
                            message_count=pre_turn_count,
                            session_meta={
                                "title": session.title,
                                "module": session.module,
                                "source": session.source or "parachute",
                                "agent_type": session.agent_type or "",
                                "created_at": (
                                    session.created_at.isoformat()
                                    if session.created_at else None
                                ),
                            },
                        )
                    except Exception as e:
                        logger.warning(
                            f"write_turn_messages error: {e}"
                        )

                asyncio.create_task(_write_messages())

            duration_ms = int((time.time() - start_time) * 1000)
            yield DoneEvent(
                response=result_text,
                session_id=captured_session_id or session.id,
                working_directory=working_directory,
                message_count=session.message_count + 2 + inject_count,
                model=captured_model,
                duration_ms=duration_ms,
                tool_calls=tool_calls if tool_calls else None,
                permission_denials=None,  # DIRECT trust bypasses permissions
                session_resume=resume_info.model_dump(),
            ).model_dump(by_alias=True)

        except asyncio.CancelledError:
            end_reason = "cancelled"
            yield AbortedEvent(
                message="Stream cancelled",
                session_id=captured_session_id or session.id,
                partial_response=result_text if result_text else None,
            ).model_dump(by_alias=True)
            raise

        except Exception as e:
            end_reason = f"error: {e}"
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

        finally:
            # Clean up active_streams for sessions registered after
            # finalization (new sessions that started as "pending").
            if captured_session_id:
                self.active_streams.pop(captured_session_id, None)
                self.active_stream_queues.pop(captured_session_id, None)

            session_label = captured_session_id or (session.id[:8] if session.id else "unknown")
            logger.info(
                f"Stream ended: session={session_label}, reason={end_reason}, "
                f"result_len={len(result_text)}, model={captured_model}"
            )

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
        if event_type == "thinking":
            ctx.sbx["had_content"] = True
            ctx.sbx["content_blocks"].append(
                {"type": "thinking", "text": event.get("content", "")}
            )
        elif event_type == "tool_use":
            ctx.sbx["had_content"] = True
            # Entrypoint nests tool data under "tool" key; fall back to root
            tool_data = event.get("tool", event)
            ctx.sbx["content_blocks"].append({
                "type": "tool_use",
                "id": tool_data.get("id", ""),
                "name": tool_data.get("name", ""),
                "input": tool_data.get("input", {}),
            })
        elif event_type == "tool_result":
            ctx.sbx["had_content"] = True
            ctx.sbx["content_blocks"].append({
                "type": "tool_result",
                "toolUseId": event.get("toolUseId", ""),
                "content": event.get("content", ""),
                "isError": event.get("isError", False),
            })
        elif event_type == "text":
            ctx.sbx["had_content"] = True
            text_content = event.get("content", "")
            # SDK text events carry the full accumulated text, not a delta.
            # Replace the previous text block to avoid duplication.
            blocks = ctx.sbx["content_blocks"]
            if blocks and blocks[-1].get("type") == "text":
                blocks[-1]["text"] = text_content
            else:
                blocks.append({"type": "text", "text": text_content})
        elif event_type == "model":
            ctx.captured_model = event.get("model")

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

        if event_type == "done":
            # Build a proper DoneEvent instead of passing through the bare dict
            result_parts = [
                b.get("text", "") for b in ctx.sbx["content_blocks"]
                if b.get("type") == "text"
            ]
            tool_calls_list = [
                b for b in ctx.sbx["content_blocks"]
                if b.get("type") == "tool_use"
            ] or None
            yield DoneEvent(
                response="\n".join(result_parts),
                session_id=ctx.sandbox_sid,
                working_directory=ctx.effective_working_dir,
                message_count=(ctx.sbx["session"].message_count or 0) + 2,
                model=ctx.captured_model,
                duration_ms=int((time.time() - ctx.start_time) * 1000),
                tool_calls=tool_calls_list,
            ).model_dump(by_alias=True)
        else:
            yield event

    async def _run_sandboxed(
        self,
        session: Any,
        caps: CapabilityBundle,
        actual_message: str,
        effective_prompt: str,
        effective_working_dir: Optional[str],
        is_new: bool,
        model: Optional[str],
        message: str,
        agent_type: Optional[str],
        captured_model: Optional[str],
        mode: str = "converse",
        interrupt: "QueryInterrupt | None" = None,
    ) -> AsyncGenerator[dict, None]:
        """Run the sandboxed (Docker container) execution path.

        Async generator that yields all SSE events for the sandboxed path.
        Called by ``run_streaming()`` only after confirming Docker is available.
        """
        # Use a real session ID — "pending" would cause SDK inside the container
        # to try resuming a nonexistent session
        sandbox_sid = session.id if session.id != "pending" else str(uuid.uuid4())

        # Convert host working directory to container path.
        # ~/X → /home/sandbox/X (preserves home-relative structure)
        sandbox_wd = None
        if effective_working_dir:
            wd = str(effective_working_dir)
            home_str = str(Path.home())
            if wd.startswith(home_str):
                relative = wd[len(home_str):].lstrip("/")
                sandbox_wd = f"/home/sandbox/{relative}" if relative else "/home/sandbox"
            else:
                # Absolute path outside home — mount at /home/sandbox/<path>
                sandbox_wd = f"/home/sandbox{wd}"

        sandbox_paths = list(session.permissions.allowed_paths)
        if sandbox_wd and sandbox_wd not in sandbox_paths:
            sandbox_paths.append(sandbox_wd)

        logger.info(
            f"Running sandboxed execution for session {sandbox_sid[:8]} "
            f"wd={sandbox_wd} paths={sandbox_paths}"
        )

        sandbox_model = model or self.settings.default_model

        # Build MCP config for sandbox: only HTTP/SSE servers survive into Docker.
        # Stdio servers (including the built-in "parachute" stdio MCP) cannot run
        # inside the container. Vault tools come via the HTTP MCP bridge instead.
        from parachute.lib.mcp_loader import _get_server_type

        sandbox_mcps: dict[str, Any] = {}
        if caps.resolved_mcps:
            for name, cfg in caps.resolved_mcps.items():
                if _get_server_type(cfg) != "stdio":
                    sandbox_mcps[name] = cfg
                else:
                    logger.debug(f"Filtered stdio MCP '{name}' from sandbox session")

        # Inject HTTP MCP bridge for scoped vault tool access (fail closed).
        sandbox_token: str | None = None
        try:
            from parachute.core.interfaces import get_registry
            from parachute.lib.sandbox_tokens import SandboxTokenContext

            token_store = get_registry().get("SandboxTokenStore")
            if token_store is not None:
                from parachute.api.mcp_bridge import build_http_mcp_config
                from parachute.api.mcp_tools import CHAT_TOOLS

                token_ctx = SandboxTokenContext(
                    session_id=sandbox_sid,
                    trust_level="sandboxed",
                    agent_name=None,  # Chat sessions, not callers
                    allowed_writes=[],  # Read-only for chat sessions
                    allowed_tools=CHAT_TOOLS,
                )
                sandbox_token = token_store.create_token(token_ctx)
                sandbox_mcps["parachute"] = build_http_mcp_config(sandbox_token)
                logger.info(
                    f"Injected HTTP MCP bridge for sandbox session {sandbox_sid[:8]}"
                )
            else:
                logger.warning(
                    f"SandboxTokenStore not available — sandbox session "
                    f"{sandbox_sid[:8]} will have no vault MCP tools"
                )
        except Exception as e:
            logger.warning(f"Failed to inject MCP bridge for sandbox: {e}")
            # Fail closed: remove any leftover "parachute" entry so the
            # stdio MCP server doesn't leak into the container.
            sandbox_mcps.pop("parachute", None)

        sandbox_config = AgentSandboxConfig(
            session_id=sandbox_sid,
            agent_type=agent_type or "chat",
            allowed_paths=sandbox_paths,
            network_enabled=True,
            mcp_servers=sandbox_mcps,
            plugin_dirs=caps.plugin_dirs,
            agents=caps.agents_dict,
            working_directory=sandbox_wd,
            model=sandbox_model,
            system_prompt=effective_prompt,
            use_preset=False,
            session_source=session.source,
            timeout_seconds=self.settings.sandbox_timeout,
            readline_timeout=self.settings.sandbox_readline_timeout,
            tools=PARACHUTE_TOOLS,
            disallowed_tools=PARACHUTE_DISALLOWED_TOOLS,
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
                    history_lines.append(f"[{role}]: {_content_as_text(msg['content'])}")
                history_block = "\n".join(history_lines)
                sandbox_message = (
                    f"<conversation_history>\n{history_block}\n"
                    f"</conversation_history>\n\n{actual_message}"
                )
                logger.info(
                    f"Injected {len(prior_messages)} prior messages "
                    f"into sandbox prompt for session {sandbox_sid[:8]}"
                )

        # Ensure every sandboxed session has a container record
        if not session.container_id:
            auto_slug = str(uuid.uuid4()).replace("-", "")[:12]
            await self.session_store.create_container(
                slug=auto_slug,
                display_name=f"Session {sandbox_sid[:8]}",
            )
            await self.session_store.update_session(
                session.id,
                SessionUpdate(container_id=auto_slug),
            )
            session.container_id = auto_slug
            logger.info(
                f"Auto-created container {auto_slug} for session {sandbox_sid[:8]}"
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
            container_slug=session.container_id,
        )

        sbx = {
            "had_content": False,
            "content_blocks": [],
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
            start_time=time.time(),
        )

        # Process sandbox events; retry with history injection if resume fails
        retry_with_history = False
        interrupted = False
        try:
            async for event in sandbox_stream:
                # Check for interrupt (stop button)
                if interrupt and interrupt.is_interrupted:
                    logger.info(f"Sandbox session {sandbox_sid[:8]} interrupted by user")
                    interrupted = True
                    break

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

            if retry_with_history and not interrupted:
                retry_message = actual_message
                prior_messages = await self.session_manager._load_sdk_messages(
                    sbx["session"]
                )
                if prior_messages:
                    history_lines = []
                    for msg in prior_messages:
                        role = msg["role"].upper()
                        history_lines.append(f"[{role}]: {_content_as_text(msg['content'])}")
                    history_block = "\n".join(history_lines)
                    retry_message = (
                        f"<conversation_history>\n{history_block}\n"
                        f"</conversation_history>\n\n{actual_message}"
                    )
                retry_stream = self._sandbox.run_session(
                    session_id=sandbox_sid,
                    config=sandbox_config,
                    message=retry_message,
                    container_slug=session.container_id,
                    fresh_session=True,  # Skip --session-id to avoid transcript conflict
                )
                async for event in retry_stream:
                    if interrupt and interrupt.is_interrupted:
                        logger.info(
                            f"Sandbox session {sandbox_sid[:8]} interrupted "
                            f"during retry"
                        )
                        interrupted = True
                        break
                    async for yielded in self._process_sandbox_event(event, ctx):
                        yield yielded

            if interrupted:
                yield AbortedEvent(
                    message="Stream cancelled",
                    session_id=sandbox_sid,
                ).model_dump(by_alias=True)

        finally:
            # Revoke sandbox MCP token after stream completes or is interrupted.
            # Reuse the token_store captured at creation time to avoid registry
            # lookup races during shutdown.
            if sandbox_token and token_store is not None:
                try:
                    token_store.revoke_token(sandbox_token)
                except Exception:
                    pass

        session = sbx["session"]

        if not sbx["had_content"]:
            logger.warning("Sandbox produced no content output")

        # Increment message count for sandbox sessions
        if sbx["had_content"] and sandbox_sid:
            try:
                await self.session_manager.increment_message_count(sandbox_sid, 2)
            except Exception as e:
                logger.warning(
                    f"Failed to increment message count for {sandbox_sid[:8]}: {e}"
                )

        # Write Message nodes for sandbox sessions (fire-and-forget)
        if sbx["had_content"] and sandbox_sid:
            text_parts = [
                b.get("text", "") for b in sbx["content_blocks"]
                if b.get("type") == "text"
            ]
            tool_calls_list = [
                {"name": b.get("name", ""), "input": b.get("input", {})}
                for b in sbx["content_blocks"] if b.get("type") == "tool_use"
            ]
            sbx_result_text = "\n".join(text_parts)
            if sbx["message"]:
                from parachute.core.bridge_agent import summarize_tool_calls

                tools_summary = summarize_tool_calls(tool_calls_list)
                final_session = sbx["session"]
                # No thinking blocks in sandboxed path (Docker doesn't expose them)
                msg_status = "interrupted" if interrupted else "complete"
                pre_turn_count = (final_session.message_count or 0)

                async def _write_sandbox_messages():
                    try:
                        await self.session_store.write_turn_messages(
                            session_id=sandbox_sid,
                            human_content=sbx["message"],
                            machine_content=sbx_result_text,
                            tools_used=tools_summary,
                            thinking=None,  # sandboxed: no thinking blocks
                            status=msg_status,
                            message_count=pre_turn_count,
                            session_meta={
                                "title": final_session.title,
                                "module": final_session.module,
                                "source": final_session.source or "parachute",
                                "agent_type": final_session.agent_type or "",
                                "created_at": (
                                    final_session.created_at.isoformat()
                                    if final_session.created_at else None
                                ),
                            },
                        )
                    except Exception as e:
                        logger.warning(
                            f"write_turn_messages error (sandbox): {e}"
                        )

                asyncio.create_task(_write_sandbox_messages())

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
        container_memory: Optional[str] = None,
    ) -> tuple[str, dict[str, Any]]:
        """
        Build the system prompt.

        Assembles PARACHUTE_PROMPT as the base, then appends runtime context:
        - Vault-level CLAUDE.md (outside the project root)
        - Container context, working directory framing
        - Prior conversation history
        - Explicitly selected context files
        - Credential discoverability

        The SDK handles project-level discovery (CLAUDE.md, .claude/ commands/skills/agents)
        via setting_sources=["project"].

        Note: Dynamic tool guidance is injected separately by run_streaming()
        after capability discovery resolves the trust level.

        Returns:
            Tuple of (prompt_string, metadata_dict) for transparency
        """
        # Track metadata for transparency
        metadata: dict[str, Any] = {
            "prompt_source": "parachute",
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
            # The caller uses system_prompt for a full prompt override
            return custom_prompt, metadata

        # Handle non-vault agents with their own prompts
        if agent.system_prompt and agent.name != "vault-agent":
            metadata["prompt_source"] = "agent"
            metadata["prompt_source_path"] = agent.path
            metadata["total_prompt_tokens"] = len(agent.system_prompt) // 4
            # Agent has custom prompt - return it for full override
            return agent.system_prompt, metadata

        # Unified Parachute prompt — always the base, regardless of mode
        append_parts.append(PARACHUTE_PROMPT)

        # Load vault-level CLAUDE.md (outside the project root).
        # SDK handles project-level CLAUDE.md via setting_sources=["project"].
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

        # Load context notes from graph (user profile, preferences, current focus, etc.)
        try:
            context_section = await self._load_context_notes()
            if context_section:
                append_parts.append(context_section)
                metadata["context_notes_loaded"] = True
        except Exception as e:
            logger.warning(f"Failed to load context notes: {e}")

        # Container context (core_memory from Container node) — injected after mode framing
        if container_memory:
            append_parts.append(f"## Container Context\n\n{container_memory}")

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

    # Max chars for all context notes combined
    _MAX_CONTEXT_CHARS = 8000

    async def _load_context_notes(self) -> str | None:
        """Load context notes from the graph for injection into the system prompt.

        Queries all Note nodes with note_type='context' and status='active',
        formats them as markdown sections, and returns the combined string.
        Returns None if no context notes exist or graph is unavailable.
        """
        try:
            graph = self.session_store.graph
        except Exception:
            return None

        rows = await graph.execute_cypher(
            "MATCH (n:Note) "
            "WHERE n.note_type = 'context' AND n.status = 'active' "
            "RETURN n.title AS title, n.content AS content "
            "ORDER BY n.title",
            None,
        )

        if not rows:
            return None

        parts = ["## User Context\n"]
        total_chars = 0

        for row in rows:
            title = row.get("title") or "Untitled"
            content = row.get("content") or ""
            section = f"### {title}\n\n{content}\n"

            if total_chars + len(section) > self._MAX_CONTEXT_CHARS:
                break
            parts.append(section)
            total_chars += len(section)

        return "\n".join(parts) if len(parts) > 1 else None

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
        container_id = session.container_id if session else None

        result = await self.session_manager.delete_session(session_id)

        if result and container_id:
            # Remove the container env if no other sessions reference it.
            # Atomic check-and-delete prevents double-remove when two sessions
            # sharing the same env are deleted concurrently.
            try:
                deleted = await self.session_store.delete_container_if_unreferenced(
                    container_id
                )
                if deleted:
                    await self._sandbox.delete_container(container_id)
                    logger.info(
                        f"Removed container env {container_id} with session {session_id[:8]}"
                    )
            except Exception as e:
                logger.warning(
                    f"Failed to clean up container env {container_id}: {e}"
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

        For sandboxed sessions, reads from the container's bind-mounted JSONL
        first (the authoritative source).  Falls back to ~/.claude/projects/.

        Args:
            session_id: The session ID
            after_compact: If True, only return events after the last compact boundary
            segment_index: If provided, only return events for that segment
            include_segment_metadata: If True, include metadata about all segments

        Returns:
            Dictionary with events and optional segment metadata
        """
        import json

        # Resolve transcript path via the shared helper (container → host → fallback)
        session_file = None
        try:
            session = await self.session_manager.db.get_session(session_id)
            if session:
                session_file = self.session_manager.find_transcript_path(
                    session_id,
                    working_directory=session.working_directory,
                    container_id=session.container_id,
                )
        except Exception:
            pass

        # Fallback: try without session metadata (e.g. orphaned transcripts)
        if not session_file:
            session_file = self.session_manager.find_transcript_path(session_id)

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
