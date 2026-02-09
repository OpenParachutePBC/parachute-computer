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
from pathlib import Path
from typing import Any, AsyncGenerator, Optional

from parachute.config import Settings, get_settings
from parachute.core.claude_sdk import query_streaming, QueryInterrupt
from parachute.core.permission_handler import PermissionHandler
from parachute.core.sandbox import DockerSandbox, AgentSandboxConfig
from parachute.core.skills import generate_runtime_plugin, cleanup_runtime_plugin
from parachute.core.agents import discover_agents, agents_to_sdk_format
from parachute.core.session_manager import SessionManager
from parachute.db.database import Database
from parachute.lib.agent_loader import build_system_prompt, load_agent
from parachute.lib.context_loader import format_context_for_prompt, load_agent_context
from parachute.core.context_folders import ContextFolderService
from parachute.core.capability_filter import filter_by_trust_level, filter_capabilities, trust_rank
from parachute.lib.mcp_loader import load_mcp_servers, resolve_mcp_servers, validate_and_filter_servers
from parachute.models.agent import AgentDefinition, AgentType, create_vault_agent
from parachute.models.events import (
    AbortedEvent,
    DoneEvent,
    ErrorEvent,
    InitEvent,
    ModelEvent,
    PermissionDeniedEvent,
    PermissionRequestEvent,
    PromptMetadataEvent,
    SessionEvent,
    SessionUnavailableEvent,
    TextEvent,
    ThinkingEvent,
    ToolResultEvent,
    ToolUseEvent,
    UserMessageEvent,
    UserQuestionEvent,
)
from parachute.models.session import ResumeInfo, SessionSource, TrustLevel

logger = logging.getLogger(__name__)


def generate_title_from_message(message: str, max_length: int = 60) -> str:
    """
    Generate a session title from the first user message.

    Takes the first line or sentence, truncates to max_length.
    """
    # Take first line
    first_line = message.split('\n')[0].strip()

    # If too long, truncate at word boundary
    if len(first_line) > max_length:
        truncated = first_line[:max_length]
        # Try to break at last space
        last_space = truncated.rfind(' ')
        if last_space > max_length // 2:
            truncated = truncated[:last_space]
        return truncated + "..."

    return first_line


# Default system prompt for vault agent
DEFAULT_VAULT_PROMPT = """# Parachute Agent

You are an AI companion in Parachute - an open, local-first tool for connected thinking.

## Your Role

You are a **thinking partner and memory extension**. Help the user:
- Think through ideas and problems
- Remember context from past conversations
- Explore topics and make connections
- Find information when they need it

## How to Help

- **Be conversational** - This is a thinking partnership, not a formal assistant relationship
- **Ask good questions** - Help the user think through problems, don't just answer
- **Be direct** - Skip flattery and respond directly to what they're asking
- **Personalize responses** - Search the vault for context when the user asks personal questions

## When to Search

**Search the vault FIRST when:**
- User asks for personalized recommendations ("what should I...")
- User references past conversations or projects
- User asks about their own thoughts, ideas, or decisions
- You need context about the user's preferences or history

**Use web search when:**
- User needs current/external information (news, docs, research)
- The question is about something outside the vault
- You need to look up facts, not personal context

## Available Tools

### Vault Search (mcp__parachute__*)
Your primary tools for understanding the user's context:

- **mcp__parachute__search_sessions** - Search past conversations by keyword
- **mcp__parachute__list_recent_sessions** - See recent chat sessions
- **mcp__parachute__get_session** - Read a specific conversation
- **mcp__parachute__search_journals** - Search Daily voice journal entries
- **mcp__parachute__list_recent_journals** - See recent journal dates
- **mcp__parachute__get_journal** - Read a specific day's journal

### Web Tools
- **WebSearch** - Look up current information online
- **WebFetch** - Read content from URLs

## Handling Attachments

When the user attaches files to their message:
- **Images**: ALWAYS use the Read tool to view the image and describe/analyze what you see. Don't just acknowledge the attachment - actually look at it!
- **PDFs**: Use the Read tool to read the PDF content
- **Code/Text files**: The content is included inline, so you can read it directly from the message

The user expects you to engage with their attachments, not just confirm they were received.

### Other MCP Tools
Additional tools may be available depending on which modules are connected.
Check the tool list for mcp__* tools from other servers.

## Skills System

Skills are reusable AI capabilities that can be invoked via the `/skill` command or Skill tool.
Skills are stored in `.skills/` and may include:
- Creative workflows (image/video generation)
- Code analysis patterns
- Research methodologies
- Custom prompts and personas

When a skill is relevant, invoke it with the Skill tool. Skills have specialized prompts and tool access configured for their purpose.

## Creating Skills

Users can create skills in their vault at `.skills/skill-name/SKILL.md`:

```markdown
---
name: My Skill
description: What this skill does
allowed-tools: [Read, Write, Bash]
---

# Skill Instructions

Your prompt/instructions here...
```

Skills can also be single files at `.skills/skill-name.md`.
"""


class Orchestrator:
    """
    Central agent execution controller.

    Manages the lifecycle of agent interactions with streaming support.
    """

    def __init__(self, vault_path: Path, database: Database, settings: Settings):
        """Initialize orchestrator."""
        self.vault_path = vault_path
        self.database = database
        self.settings = settings

        # Session manager
        self.session_manager = SessionManager(vault_path, database)

        # Shared Docker sandbox instance (TTL-cached availability checks)
        self._sandbox = DockerSandbox(
            vault_path=vault_path,
            claude_token=settings.claude_code_oauth_token,
        )

        # Active streams for abort functionality
        self.active_streams: dict[str, QueryInterrupt] = {}

        # Pending permission requests
        self.pending_permissions: dict[str, PermissionHandler] = {}

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
        model: Optional[str] = None,
        workspace_id: Optional[str] = None,
    ) -> AsyncGenerator[dict[str, Any], None]:
        """
        Run an agent with streaming response.

        This is the main entry point for chat interactions.

        Yields:
            SSE events as dictionaries
        """
        start_time = time.time()

        # Load agent
        logger.info(f"run_streaming: agent_path={agent_path!r}, agent_type={agent_type!r}")
        if agent_path and agent_path != "vault-agent":
            logger.info(f"Loading custom agent from: {agent_path}")
            agent = await load_agent(agent_path, self.vault_path)
            if not agent:
                logger.warning(f"Agent not found at path: {agent_path}, vault_path: {self.vault_path}")
                yield ErrorEvent(error=f"Agent not found: {agent_path}").model_dump(by_alias=True)
                return
            logger.info(f"Loaded agent: {agent.name}")
        else:
            logger.info("Using default vault agent")
            agent = create_vault_agent()

        # Load workspace config if specified
        workspace_config = None
        if workspace_id:
            from parachute.core.workspaces import get_workspace
            workspace_config = get_workspace(self.vault_path, workspace_id)
            if workspace_config:
                logger.info(f"Loaded workspace: {workspace_id} ({workspace_config.name})")
                # Apply workspace defaults (explicit params take priority)
                if not working_directory and workspace_config.working_directory:
                    working_directory = workspace_config.working_directory
                if not model and workspace_config.model:
                    model = workspace_config.model
            else:
                logger.warning(f"Workspace not found: {workspace_id}")

        # Get or create session (before building prompt so we can load prior conversation)
        session, resume_info, is_new = await self.session_manager.get_or_create_session(
            session_id=session_id,
            module=module,
            working_directory=working_directory,
            trust_level=trust_level,
        )

        # Fall back to session's stored workspace for workspace defaults
        # (e.g., when user resumes a session without the workspace filter active)
        if not workspace_config and hasattr(session, 'workspace_id') and session.workspace_id:
            from parachute.core.workspaces import get_workspace
            workspace_config = get_workspace(self.vault_path, session.workspace_id)
            if workspace_config:
                workspace_id = session.workspace_id
                logger.info(f"Using session's stored workspace: {workspace_id} ({workspace_config.name})")
                if not working_directory and workspace_config.working_directory:
                    working_directory = workspace_config.working_directory
                if not model and workspace_config.model:
                    model = workspace_config.model

        # For imported sessions, handle context continuity
        # - Claude Code sessions with existing JSONL: use SDK resume directly
        # - Other imports (Claude Web, ChatGPT): inject history as context
        effective_prior_conversation = prior_conversation
        imported_sources = (SessionSource.CLAUDE_CODE, SessionSource.CLAUDE_WEB, SessionSource.CHATGPT)
        if not prior_conversation and session.source in imported_sources:
            # Check if SDK can resume this session directly
            sdk_can_resume = self.session_manager._check_sdk_session_exists(
                session.id, session.working_directory
            )

            if session.source == SessionSource.CLAUDE_CODE and sdk_can_resume:
                # Claude Code session with existing JSONL - let SDK resume directly
                logger.info(f"Claude Code session has JSONL, using SDK resume: {session.id[:8]}...")
                # Don't inject prior conversation, don't force is_new
                # SDK will load the full history automatically
            else:
                # No SDK file or non-Claude-Code import - inject as context
                loaded_prior = await self.session_manager.get_prior_conversation(session)
                if loaded_prior:
                    effective_prior_conversation = loaded_prior
                    logger.info(f"Loaded prior conversation for {session.source.value} session: {session.id[:8]}...")
                    # Force new SDK session since we're injecting context, not resuming
                    is_new = True

        # Extract config overrides from session metadata (set via PATCH /config endpoint)
        config_overrides = (session.metadata or {}).get("config_overrides", {}) if hasattr(session, "metadata") else {}

        # Determine working directory first (needed for prompt building)
        # Priority: explicit param > config_overrides > session's stored value > vault path
        # Note: working_directory is stored as RELATIVE to vault_path in the database
        override_working_dir = config_overrides.get("working_directory")
        effective_working_dir: Optional[str] = working_directory or override_working_dir or session.working_directory
        effective_cwd = self.session_manager.resolve_working_directory(effective_working_dir)

        # Validate working directory exists - fall back appropriately
        if not effective_cwd.exists():
            # For existing sessions, we need to find where the transcript actually is
            # and use that cwd so the SDK can locate it
            if not is_new and session.id != "pending":
                resume_cwd = self.session_manager.get_session_resume_cwd(session.id)
                if resume_cwd:
                    logger.info(
                        f"Working directory {effective_cwd} doesn't exist, "
                        f"using transcript's original cwd: {resume_cwd}"
                    )
                    effective_cwd = Path(resume_cwd)
                    effective_working_dir = resume_cwd
                else:
                    logger.warning(
                        f"Working directory does not exist: {effective_cwd}, "
                        f"falling back to vault path: {self.vault_path}"
                    )
                    effective_cwd = self.vault_path
                    effective_working_dir = None
            else:
                logger.warning(
                    f"Working directory does not exist: {effective_cwd}, "
                    f"falling back to vault path: {self.vault_path}"
                )
                effective_cwd = self.vault_path
                effective_working_dir = None

        # Apply system prompt override from config_overrides (only if no explicit prompt given)
        override_system_prompt = config_overrides.get("system_prompt")
        effective_custom_prompt = system_prompt or override_system_prompt

        # Build system prompt (after loading prior conversation, with working dir)
        effective_prompt, prompt_metadata = await self._build_system_prompt(
            agent=agent,
            custom_prompt=effective_custom_prompt,
            contexts=contexts,
            prior_conversation=effective_prior_conversation,
            working_directory=effective_working_dir,
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

        # Yield prompt metadata event for UI transparency
        yield PromptMetadataEvent(
            prompt_source=prompt_metadata["prompt_source"],
            prompt_source_path=prompt_metadata["prompt_source_path"],
            context_files=prompt_metadata["context_files"],
            context_tokens=prompt_metadata["context_tokens"],
            context_truncated=prompt_metadata["context_truncated"],
            agent_name=prompt_metadata["agent_name"],
            available_agents=prompt_metadata["available_agents"],
            base_prompt_tokens=prompt_metadata["base_prompt_tokens"],
            total_prompt_tokens=prompt_metadata["total_prompt_tokens"],
            trust_mode=session.permissions.trust_mode,
            working_directory_claude_md=prompt_metadata.get("working_directory_claude_md"),
        ).model_dump(by_alias=True)

        # Handle initial context
        actual_message = message
        if initial_context and is_new:
            if not message.strip():
                actual_message = initial_context
            else:
                actual_message = f"## Context\n\n{initial_context}\n\n---\n\n## Request\n\n{message}"

        # Handle attachments
        # For now, we save attachments to the vault and reference them in the message
        if attachments:
            attachment_parts = []
            for att in attachments:
                att_type = att.get("type", "unknown")
                file_name = att.get("fileName", "file")
                base64_data = att.get("base64Data")
                mime_type = att.get("mimeType", "application/octet-stream")

                if base64_data:
                    import base64
                    from datetime import datetime

                    # Save to Chat/assets/YYYY-MM-DD/ (date-based organization)
                    now = datetime.now()
                    date_folder = now.strftime("%Y-%m-%d")
                    asset_dir = self.vault_path / "Chat" / "assets" / date_folder
                    asset_dir.mkdir(parents=True, exist_ok=True)

                    # Generate unique filename (time-based, no date prefix since folder has date)
                    timestamp = now.strftime("%H-%M-%S")
                    ext = Path(file_name).suffix or ".bin"
                    safe_name = Path(file_name).stem[:30]  # Truncate long names
                    unique_name = f"{timestamp}_{safe_name}{ext}"
                    file_path = asset_dir / unique_name

                    # Decode and save
                    try:
                        file_bytes = base64.b64decode(base64_data)
                        file_path.write_bytes(file_bytes)
                        logger.info(f"Saved attachment: {file_path}")

                        # Use vault-relative path for display (enables UI asset fetching)
                        relative_path = f"Chat/assets/{date_folder}/{unique_name}"

                        # Build reference for the message
                        if att_type == "image":
                            # For images, use markdown image syntax with relative path
                            # Also include absolute path for Claude to read
                            attachment_parts.append(f"![{file_name}]({relative_path})\n*(Absolute path for reading: {file_path})*")
                        elif att_type in ("text", "code"):
                            # For text/code files, save to disk and reference by path
                            # Claude can use the Read tool to access the content
                            # This keeps the message size manageable for large files
                            file_size_kb = len(file_bytes) / 1024
                            attachment_parts.append(
                                f"**[{file_name}]({relative_path})** ({file_size_kb:.1f} KB)\n"
                                f"*(Absolute path for reading: {file_path})*"
                            )
                        elif att_type == "pdf":
                            # For PDFs, reference with both paths
                            attachment_parts.append(f"**[{file_name}]({relative_path})**\n*(Absolute path for reading: {file_path})*")
                        else:
                            attachment_parts.append(f"[{file_name}]({relative_path})")
                    except Exception as e:
                        logger.error(f"Failed to save attachment {file_name}: {e}")
                        attachment_parts.append(f"[Failed to attach: {file_name}]")

            if attachment_parts:
                attachment_text = "\n\n".join(attachment_parts)
                actual_message = f"{actual_message}\n\n## Attachments\n\n{attachment_text}"

        # Emit user message event immediately so clients can display it
        # This ensures the user's message is visible even if they rejoin mid-stream
        # (SDK doesn't write user messages to JSONL until response completes)
        logger.info(f"Emitting user_message event: {message[:50]}...")
        yield UserMessageEvent(content=message).model_dump(by_alias=True)

        # Handle recovery mode
        force_new = False
        if recovery_mode == "inject_context":
            # TODO: Inject context from session history
            force_new = True
        elif recovery_mode == "fresh_start":
            force_new = True

        # Set up interrupt handler
        interrupt = QueryInterrupt()
        stream_session_id = session.id if session.id != "pending" else None
        if stream_session_id:
            self.active_streams[stream_session_id] = interrupt

        # Track results
        result_text = ""
        text_blocks: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        permission_denials: list[dict[str, Any]] = []
        captured_session_id: Optional[str] = None
        captured_model: Optional[str] = None
        session_finalized = False  # Track if session has been saved to DB

        try:
            # Load MCP servers with OAuth tokens attached for HTTP servers
            # Note: SDK supports both stdio and HTTP servers, but HTTP servers need `type: "http"`
            # Wrap in try/catch for resilience - MCP misconfig shouldn't crash the server
            resolved_mcps = None
            mcp_warnings: list[str] = []
            try:
                global_mcps = await load_mcp_servers(self.vault_path)
                resolved_mcps = resolve_mcp_servers(agent.mcp_servers, global_mcps)

                # Validate and filter out problematic MCP servers
                if resolved_mcps:
                    resolved_mcps, mcp_warnings = validate_and_filter_servers(resolved_mcps)

                    # Log any warnings but continue
                    if mcp_warnings:
                        logger.warning(
                            f"MCP configuration issues (continuing with valid servers): "
                            f"{'; '.join(mcp_warnings[:3])}"
                            f"{'...' if len(mcp_warnings) > 3 else ''}"
                        )
            except Exception as e:
                # MCP loading failed entirely - log and continue without MCP
                logger.error(f"Failed to load MCP servers (continuing without MCP): {e}")
                resolved_mcps = None

            # Generate runtime plugin for skills (if any skills exist)
            plugin_dirs: list[Path] = []
            skills_plugin_dir = generate_runtime_plugin(self.vault_path)
            if skills_plugin_dir:
                plugin_dirs.append(skills_plugin_dir)
                logger.info(f"Generated skills plugin at {skills_plugin_dir}")

            # Discover user plugins (~/.claude/plugins/)
            settings = get_settings()
            if settings.include_user_plugins:
                user_plugin_dir = Path.home() / ".claude" / "plugins"
                if user_plugin_dir.is_dir():
                    for entry in user_plugin_dir.iterdir():
                        if entry.is_dir():
                            plugin_dirs.append(entry)
                            logger.info(f"Loaded user plugin: {entry.name}")

            # Load additional configured plugin directories
            for dir_str in settings.plugin_dirs:
                plugin_path = Path(dir_str).expanduser().resolve()
                if plugin_path.is_dir():
                    plugin_dirs.append(plugin_path)
                    logger.info(f"Loaded configured plugin: {plugin_path}")
                else:
                    logger.warning(f"Plugin directory not found, skipping: {plugin_path}")

            # Load custom agents from .parachute/agents/
            custom_agents = discover_agents(self.vault_path)
            agents_dict = agents_to_sdk_format(custom_agents) if custom_agents else None
            if agents_dict:
                logger.info(f"Loaded {len(agents_dict)} custom agents")

            # Determine effective trust level early (needed for capability filtering)
            # Trust level routing: session → workspace floor → client override
            session_trust = session.get_trust_level()

            if workspace_config and workspace_config.trust_level:
                try:
                    # Map legacy workspace trust values
                    _legacy = {"full": "trusted", "vault": "trusted", "sandboxed": "untrusted"}
                    ws_trust_str = _legacy.get(workspace_config.trust_level, workspace_config.trust_level)
                    workspace_trust = TrustLevel(ws_trust_str)
                    if trust_rank(workspace_trust) > trust_rank(session_trust):
                        logger.info(f"Workspace trust floor restricts session from {session_trust.value} to {workspace_trust.value}")
                        session_trust = workspace_trust
                except ValueError:
                    logger.warning(f"Invalid workspace trust_level: {workspace_config.trust_level}")

            if trust_level:
                try:
                    # Map legacy client trust values
                    _legacy = {"full": "trusted", "vault": "trusted", "sandboxed": "untrusted"}
                    client_trust_str = _legacy.get(trust_level, trust_level)
                    requested = TrustLevel(client_trust_str)
                    if trust_rank(requested) >= trust_rank(session_trust):
                        session_trust = requested
                    else:
                        logger.warning(
                            f"Client tried to escalate trust from {session_trust.value} to {requested.value}, ignoring"
                        )
                except ValueError:
                    logger.warning(f"Invalid trust_level from client: {trust_level}")

            effective_trust = session_trust.value

            # Stage 1: Trust-level capability filtering
            # MCPs with trust_level annotation are only available at that trust or above
            if resolved_mcps:
                pre_count = len(resolved_mcps)
                resolved_mcps = filter_by_trust_level(resolved_mcps, effective_trust)
                if len(resolved_mcps) < pre_count:
                    logger.info(
                        f"Trust filter ({effective_trust}): "
                        f"{pre_count} → {len(resolved_mcps)} MCPs"
                    )

            # Stage 2: Workspace capability filtering
            if workspace_config and workspace_config.capabilities:
                agent_names = list(agents_dict.keys()) if agents_dict else []
                filtered = filter_capabilities(
                    capabilities=workspace_config.capabilities,
                    all_mcps=resolved_mcps,
                    all_agents=agent_names,
                    plugin_dirs=plugin_dirs,
                )
                resolved_mcps = filtered.mcp_servers or None
                plugin_dirs = filtered.plugin_dirs
                if agents_dict and filtered.agents is not None:
                    agents_dict = {k: v for k, v in agents_dict.items() if k in filtered.agents}
                logger.info(
                    f"Workspace {workspace_id} filtered: "
                    f"mcps={len(resolved_mcps) if resolved_mcps else 0}, "
                    f"plugins={len(plugin_dirs)}, "
                    f"agents={len(agents_dict) if agents_dict else 0}"
                )

            # Set up permission handler with event callbacks
            def on_permission_denial(denial: dict) -> None:
                """Track permission denials for reporting in done event."""
                permission_denials.append(denial)

            # Track pending user question for SSE events
            pending_user_question: dict | None = None

            def on_user_question(request) -> None:
                """Handle AskUserQuestion - store for SSE event emission."""
                nonlocal pending_user_question
                pending_user_question = {
                    "request_id": request.id,
                    "questions": request.questions,
                }
                logger.info(f"User question pending: {request.id} with {len(request.questions)} questions")

            permission_handler = PermissionHandler(
                session=session,
                vault_path=str(self.vault_path),
                on_denial=on_permission_denial,
                on_user_question=on_user_question,
            )

            # Store handler for potential API grant/deny calls
            self.pending_permissions[session.id] = permission_handler

            # Determine resume session ID
            # Only resume if:
            # 1. Session ID is not "pending" (i.e., we have an ID)
            # 2. Not a new session (is_new=False means SDK has this session)
            # 3. Not forcing a fresh start
            # 4. SDK actually has a JSONL transcript for this session
            resume_id = None
            if session.id != "pending" and not is_new and not force_new:
                # Verify SDK actually has a session file to resume
                # Bot-created sessions have DB records but no SDK JSONL yet
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

            # Get Claude token from settings for SDK auth
            claude_token = get_settings().claude_code_oauth_token

            logger.info(f"Resume decision: session.id={session.id}, is_new={is_new}, force_new={force_new}, resume_id={resume_id}")

            # Run query
            current_text = ""

            # Use session-based permission handler for tool access control
            # Trust mode (default): Use bypassPermissions for backwards compatibility
            # Restricted mode: Uses can_use_tool callback for interactive permission checks
            trust_mode = session.permissions.trust_mode
            logger.debug(f"Session trust_mode={trust_mode}: {session.id}")

            # Create SDK callback for tool permission checks
            # This enables interactive tools like AskUserQuestion to pause and wait for user input
            sdk_can_use_tool = permission_handler.create_sdk_callback()

            # effective_trust was determined earlier (before capability filtering)

            if effective_trust == "untrusted":
                if await self._sandbox.is_available():
                    # Use a real session ID for sandbox — "pending" would cause the SDK
                    # inside the container to try resuming a nonexistent session
                    sandbox_sid = session.id if session.id != "pending" else str(uuid.uuid4())
                    # Working directory is already /vault/... — pass directly
                    sandbox_wd = str(effective_working_dir) if effective_working_dir else None

                    sandbox_paths = list(session.permissions.allowed_paths)
                    # Auto-add working directory to allowed_paths so it gets mounted
                    if sandbox_wd and sandbox_wd not in sandbox_paths:
                        sandbox_paths.append(sandbox_wd)

                    logger.info(
                        f"Running sandboxed execution for session {sandbox_sid[:8]} "
                        f"wd={sandbox_wd} paths={sandbox_paths}"
                    )

                    sandbox_config = AgentSandboxConfig(
                        session_id=sandbox_sid,
                        agent_type=agent.type.value if agent.type else "chat",
                        allowed_paths=sandbox_paths,
                        network_enabled=True,  # SDK needs network for Anthropic API
                        mcp_servers=resolved_mcps,  # Pass filtered MCPs to container
                        working_directory=sandbox_wd,
                    )
                    # For continuing sandbox sessions, inject prior conversation
                    # as context. Each container is fresh and can't resume from transcripts.
                    sandbox_message = actual_message
                    if not is_new:
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

                    had_text = False
                    sandbox_response_text = ""
                    async for event in self._sandbox.run_agent(sandbox_config, sandbox_message):
                        event_type = event.get("type", "")
                        if event_type == "error":
                            sandbox_err = event.get("error") or event.get("message") or "Unknown sandbox error"
                            logger.error(f"Sandbox error: {sandbox_err}")
                            yield ErrorEvent(
                                error=f"Sandbox: {sandbox_err}",
                            ).model_dump(by_alias=True)
                        else:
                            # Rewrite session IDs in sandbox events to use our canonical
                            # sandbox_sid (the one saved to DB), not the container's
                            # internal SDK session ID which the client can't resume
                            if event_type in ("session", "done") and "sessionId" in event:
                                event = {**event, "sessionId": sandbox_sid, "trustLevel": effective_trust}
                            if event_type == "text":
                                had_text = True
                                # Track full response text for synthetic transcript
                                sandbox_response_text = event.get("content", sandbox_response_text)

                            # Finalize BEFORE yielding "done" to prevent race condition:
                            # client receives "done", sends next message, but server
                            # hasn't written the transcript yet
                            if event_type == "done":
                                if is_new and not session_finalized:
                                    try:
                                        title = generate_title_from_message(message) if message.strip() else None
                                        session = await self.session_manager.finalize_session(
                                            session, sandbox_sid, captured_model, title=title,
                                            agent_type=agent_type,
                                            workspace_id=workspace_id,
                                        )
                                        session_finalized = True
                                        logger.info(f"Finalized sandbox session: {sandbox_sid[:8]} trust={effective_trust}")
                                    except Exception as e:
                                        logger.error(f"Failed to finalize sandbox session {sandbox_sid[:8]}: {e}")

                                # Write synthetic transcript to host so messages persist
                                # Docker container transcripts are lost when container exits
                                if had_text:
                                    self.session_manager.write_sandbox_transcript(
                                        sandbox_sid, actual_message, sandbox_response_text,
                                        working_directory=effective_working_dir,
                                    )

                            yield event

                    if not had_text:
                        logger.warning("Sandbox produced no text output")

                    # Increment message count for sandbox sessions
                    if had_text and sandbox_sid:
                        try:
                            await self.session_manager.increment_message_count(sandbox_sid, 2)
                        except Exception as e:
                            logger.warning(f"Failed to increment message count for {sandbox_sid[:8]}: {e}")
                    return
                else:
                    # No fallback — Docker is required for untrusted sessions
                    logger.error("Docker not available for untrusted session")
                    yield ErrorEvent(
                        error="Docker is required for untrusted sessions but is not available. "
                              "Install Docker to enable untrusted execution.",
                    ).model_dump(by_alias=True)
                    return

            # Determine if this is a full custom prompt or append content
            # Custom agents and explicit custom_prompt return full prompts (override preset)
            # vault-agent returns append content only (uses preset + CLAUDE.md hierarchy)
            is_full_prompt = prompt_metadata.get("prompt_source") in ("custom", "agent")

            async for event in query_streaming(
                prompt=actual_message,
                # Full prompt overrides preset, append content adds to it
                system_prompt=effective_prompt if is_full_prompt else None,
                system_prompt_append=effective_prompt if not is_full_prompt and effective_prompt else None,
                use_claude_code_preset=not is_full_prompt,  # Use preset unless custom/agent
                setting_sources=["project"],  # Enable CLAUDE.md hierarchy loading
                cwd=effective_cwd,
                resume=resume_id,
                tools=agent.tools if agent.tools else None,
                mcp_servers=resolved_mcps,
                permission_mode="bypassPermissions",
                can_use_tool=sdk_can_use_tool,  # Enable interactive tool permission checks (AskUserQuestion)
                plugin_dirs=plugin_dirs if plugin_dirs else None,
                agents=agents_dict,
                claude_token=claude_token,
                **({"model": model or self.settings.default_model} if (model or self.settings.default_model) else {}),
            ):
                # Check for interrupt
                if interrupt.is_interrupted:
                    break

                event_type = event.get("type")
                logger.debug(f"SDK Event: type={event_type} keys={list(event.keys())}")

                # Capture session ID and immediately save to database
                if event.get("session_id"):
                    captured_session_id = event["session_id"]
                    if stream_session_id is None:
                        stream_session_id = captured_session_id
                        self.active_streams[stream_session_id] = interrupt

                    # Immediately finalize new sessions so they appear in the chat list
                    # even if the user navigates away before the response completes
                    if is_new and not session_finalized and captured_session_id:
                        title = generate_title_from_message(message) if message.strip() else None
                        session = await self.session_manager.finalize_session(
                            session, captured_session_id, captured_model, title=title,
                            agent_type=agent_type,
                            workspace_id=workspace_id,
                        )
                        session_finalized = True
                        logger.info(f"Early finalized session: {captured_session_id[:8]}...")

                        # Update permission handler with finalized session so request_ids match
                        permission_handler.session = session
                        # Also update the pending_permissions key to use the real session ID
                        if "pending" in self.pending_permissions:
                            del self.pending_permissions["pending"]
                        self.pending_permissions[captured_session_id] = permission_handler

                        # Yield a second session event now that we have the real ID
                        # This allows the client to update its session list immediately
                        yield SessionEvent(
                            session_id=captured_session_id,
                            working_directory=working_directory,
                            resume_info=resume_info.model_dump(),
                            trust_level=trust_level,
                        ).model_dump(by_alias=True)

                # Handle different event types
                if event_type == "system" and event.get("subtype") == "init":
                    yield InitEvent(
                        tools=event.get("tools", []),
                        permission_mode=event.get("permissionMode"),
                    ).model_dump(by_alias=True)

                elif event_type == "assistant":
                    message_content = event.get("message", {})

                    # Capture model
                    if not captured_model and message_content.get("model"):
                        captured_model = message_content["model"]
                        yield ModelEvent(model=captured_model).model_dump(by_alias=True)

                    # Process content blocks
                    for block in message_content.get("content", []):
                        block_type = block.get("type")

                        if block_type == "thinking":
                            yield ThinkingEvent(
                                content=block.get("thinking", "")
                            ).model_dump(by_alias=True)

                        elif block_type == "text":
                            new_text = block.get("text", "")
                            if new_text != current_text:
                                delta = new_text[len(current_text):]
                                yield TextEvent(
                                    content=new_text,
                                    delta=delta,
                                ).model_dump(by_alias=True)
                                current_text = new_text
                                # Update result
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

                            # Special handling for AskUserQuestion - emit user_question event
                            if block.get("name") == "AskUserQuestion":
                                questions = block.get("input", {}).get("questions", [])
                                if questions and captured_session_id:
                                    # Generate request ID for answer submission
                                    tool_use_id = block.get("id", "")
                                    request_id = f"{captured_session_id}-q-{tool_use_id}"
                                    yield UserQuestionEvent(
                                        request_id=request_id,
                                        session_id=captured_session_id,
                                        questions=questions,
                                    ).model_dump(by_alias=True)
                                    logger.info(f"Emitted user_question event: {request_id}")

                            # Reset for next text block
                            current_text = ""

                elif event_type == "user":
                    # Tool results come in user messages
                    for block in event.get("message", {}).get("content", []):
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
                            delta=result_text[len(current_text):],
                        ).model_dump(by_alias=True)
                    if event.get("session_id"):
                        captured_session_id = event["session_id"]

                elif event_type == "error":
                    # SDK emitted an error event - handle it properly
                    error_msg = event.get("error", "Unknown SDK error")
                    logger.error(f"SDK error event received: {error_msg}")

                    # Check if this is a session/directory issue that's recoverable
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
                        yield ErrorEvent(
                            error=error_msg,
                            session_id=captured_session_id or session.id,
                        ).model_dump(by_alias=True)

                    # Stop processing - don't continue to done event
                    return

            # Finalize session (if not already done early)
            if is_new and captured_session_id and not session_finalized:
                # Generate title from the user's first message
                title = generate_title_from_message(message) if message.strip() else None
                session = await self.session_manager.finalize_session(
                    session, captured_session_id, captured_model, title=title,
                    agent_type=agent_type,
                    workspace_id=workspace_id,
                )
                session_finalized = True
                logger.info(f"Finalized session: {captured_session_id[:8]}...")

            # Update message count - use captured_session_id for new sessions
            # (session.id is "pending" for new sessions until finalized)
            final_session_id = captured_session_id or session.id
            if final_session_id and final_session_id != "pending":
                await self.session_manager.increment_message_count(final_session_id, 2)

            duration_ms = int((time.time() - start_time) * 1000)

            # CURATOR REMOVED - curator task queuing disabled for modular architecture
            # logger.info(f"About to queue curator: final_session_id={final_session_id}, is_pending={final_session_id == 'pending'}")
            # if final_session_id and final_session_id != "pending":
            #     await self._queue_curator_task(
            #         session_id=final_session_id,
            #         message_count=session.message_count + 2,
            #         tool_calls=tool_calls if tool_calls else None,
            #     )

            # Yield done event
            yield DoneEvent(
                response=result_text,
                session_id=captured_session_id or session.id,
                working_directory=working_directory,
                message_count=session.message_count + 2,
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

        except Exception as e:
            logger.error(f"Streaming error: {e}", exc_info=True)

            # Check if SDK session not found
            if "ENOENT" in str(e) or "not found" in str(e).lower():
                yield SessionUnavailableEvent(
                    reason="sdk_session_not_found",
                    session_id=session.id,
                    has_markdown_history=False,
                    message_count=0,
                    message="The conversation history could not be loaded.",
                ).model_dump(by_alias=True)
            else:
                yield ErrorEvent(
                    error=str(e),
                    session_id=captured_session_id or session.id,
                ).model_dump(by_alias=True)

        finally:
            # Clean up
            if stream_session_id and stream_session_id in self.active_streams:
                del self.active_streams[stream_session_id]
            if session.id in self.pending_permissions:
                del self.pending_permissions[session.id]

    async def abort_stream(self, session_id: str) -> bool:
        """Abort an active streaming session."""
        interrupt = self.active_streams.get(session_id)
        if interrupt:
            logger.info(f"Aborting stream: {session_id[:8]}...")
            interrupt.interrupt()
            return True
        return False

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
    ) -> tuple[str, dict[str, Any]]:
        """
        Build runtime additions to the system prompt.

        With setting_sources=["project"], Claude SDK automatically loads CLAUDE.md
        files from the directory hierarchy (cwd up to root). This method now only
        builds content that CANNOT be in static files:
        - Prior conversation history (runtime only)
        - Runtime-discovered skills and agents
        - Explicitly selected context files (beyond hierarchy)

        The base prompt (DEFAULT_VAULT_PROMPT) is now in ~/Parachute/CLAUDE.md
        and loaded automatically by the SDK.

        Returns:
            Tuple of (append_string, metadata_dict) for transparency
        """
        # Track metadata for transparency
        metadata: dict[str, Any] = {
            "prompt_source": "claude_code_preset",  # Using SDK preset
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

        # For vault-agent: SDK loads CLAUDE.md hierarchy automatically
        # with setting_sources=["project"]. CLAUDE.md uses @ references to include:
        # - .parachute/system.md (system prompt)
        # - parachute/*.md (bootstrap files: identity, orientation, profile, now, memory, tools)
        # No need to inject them manually here.

        # Handle explicitly selected context files (beyond automatic hierarchy)
        # These are files the user explicitly selected in the UI
        if contexts:
            context_folder_service = ContextFolderService(self.vault_path)

            # Separate folder paths from file paths
            folder_paths: list[str] = []
            file_paths: list[str] = []

            for ctx in contexts:
                if ctx.endswith(".md"):
                    file_paths.append(ctx)
                else:
                    folder_paths.append(ctx)

            # Load folder-based context (explicit selections only)
            if folder_paths:
                try:
                    chain = context_folder_service.build_chain(folder_paths, max_tokens=40000)
                    if chain.files:
                        folder_context = context_folder_service.format_chain_for_prompt(chain)
                        append_parts.append(folder_context)
                        metadata["context_files"].extend(chain.file_paths)
                        metadata["context_tokens"] += chain.total_tokens
                        metadata["context_truncated"] = chain.truncated
                        logger.info(f"Loaded {len(chain.files)} explicit context files ({chain.total_tokens} tokens)")
                except Exception as e:
                    logger.warning(f"Failed to load folder context: {e}")

            # Load legacy file-based context
            if file_paths:
                try:
                    context_result = await load_agent_context(
                        {"include": file_paths, "max_tokens": 10000},
                        self.vault_path,
                    )
                    if context_result.get("content"):
                        append_parts.append(format_context_for_prompt(context_result))
                        metadata["context_files"].extend(context_result.get("files", []))
                        metadata["context_tokens"] += context_result.get("totalTokens", 0)
                        metadata["context_truncated"] = metadata["context_truncated"] or context_result.get("truncated", False)
                except Exception as e:
                    logger.warning(f"Failed to load file context: {e}")

        # Note working directory for metadata (SDK loads CLAUDE.md automatically)
        if working_directory:
            working_dir_path = Path(working_directory)
            if not working_dir_path.is_absolute():
                working_dir_path = self.vault_path / working_directory

            # Check if CLAUDE.md exists (for metadata, SDK loads it)
            for md_name in ["AGENTS.md", "CLAUDE.md"]:
                md_path = working_dir_path / md_name
                if md_path.exists():
                    try:
                        relative_path = md_path.relative_to(self.vault_path)
                        metadata["working_directory_claude_md"] = str(relative_path)
                    except ValueError:
                        metadata["working_directory_claude_md"] = str(md_path)
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
        workspace_id: Optional[str] = None,
    ) -> list[dict[str, Any]]:
        """List all chat sessions."""
        sessions = await self.session_manager.list_sessions(
            module=module,
            archived=archived,
            search=search,
            limit=limit,
            workspace_id=workspace_id,
        )
        return [s.model_dump(by_alias=True) for s in sessions]

    async def get_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Get a session by ID with messages."""
        session = await self.session_manager.get_session_with_messages(session_id)
        if not session:
            return None

        return session.model_dump(by_alias=True)

    async def delete_session(self, session_id: str) -> bool:
        """Delete a session."""
        return await self.session_manager.delete_session(session_id)

    async def archive_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Archive a session."""
        session = await self.session_manager.archive_session(session_id)
        if session:
            return session.model_dump(by_alias=True)
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

        # Fallback: search in vault/.claude (legacy from HOME override era)
        if not session_file:
            vault_projects_dir = self.vault_path / ".claude" / "projects"
            if vault_projects_dir.exists():
                for project_dir in vault_projects_dir.iterdir():
                    if project_dir.is_dir():
                        candidate = project_dir / f"{session_id}.jsonl"
                        if candidate.exists():
                            session_file = candidate
                            logger.debug(f"Found transcript in legacy vault location: {candidate}")
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
            events = all_events[last_segment["start_index"]:last_segment["end_index"]]
        elif segment_index is not None and 0 <= segment_index < len(segments):
            # Return events for a specific segment
            segment = segments[segment_index]
            events = all_events[segment["start_index"]:segment["end_index"]]
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
                    (not after_compact and segment_index is None) or  # Full load
                    (after_compact and i == len(segments) - 1) or     # Last segment
                    (segment_index == i)                               # Specific segment
                )
                segment_metadata.append({
                    "index": i,
                    "isCompacted": seg["is_compacted"],
                    "messageCount": seg["message_count"],
                    "eventCount": seg["event_count"],
                    "startTime": seg["start_time"],
                    "endTime": seg["end_time"],
                    "preview": seg["preview"],
                    "loaded": is_loaded,
                })

            result["segments"] = segment_metadata
            result["segmentCount"] = len(segments)
            result["loadedSegmentIndex"] = (
                len(segments) - 1 if after_compact else
                segment_index if segment_index is not None else
                None  # All loaded
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
                        block.get("type") == "text" for block in content if isinstance(block, dict)
                    )
                    if has_text:
                        current_messages += 1
                        if current_first_user_message is None:
                            current_first_user_message = self._extract_preview(event)

            # Check for compact boundary
            if event_type == "system" and subtype == "compact_boundary":
                # End current segment
                if current_start < i:
                    segments.append({
                        "start_index": current_start,
                        "end_index": i,  # Exclusive, doesn't include the boundary
                        "is_compacted": True,
                        "message_count": current_messages,
                        "event_count": i - current_start,
                        "start_time": current_start_time,
                        "end_time": current_end_time,
                        "preview": current_first_user_message or "",
                    })

                # Start new segment after the boundary
                current_start = i + 1
                current_messages = 0
                current_first_user_message = None
                current_start_time = None
                current_end_time = None

        # Add final segment (everything after last compact or all events if no compact)
        if current_start < len(events):
            segments.append({
                "start_index": current_start,
                "end_index": len(events),
                "is_compacted": False,  # Current segment, not yet compacted
                "message_count": current_messages,
                "event_count": len(events) - current_start,
                "start_time": current_start_time,
                "end_time": current_end_time,
                "preview": current_first_user_message or "",
            })

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
            return text[:max_length - 3] + "..."
        return text

    # =========================================================================
    # CURATOR REMOVED - curator integration disabled for modular architecture
    # =========================================================================

    # async def _queue_curator_task(
    #     self,
    #     session_id: str,
    #     message_count: int,
    #     tool_calls: Optional[list[dict]] = None,
    # ) -> None:
    #     """
    #     Queue a curator task to run in the background.
    #
    #     Called after a message completes. The curator will:
    #     - Update session title if needed
    #     - Log commits to Daily/chat-log/
    #
    #     This is non-blocking - the task is queued and processed asynchronously.
    #     """
    #     logger.info(f"_queue_curator_task called for session {session_id[:8]}...")
    #     try:
    #         from parachute.core.curator_service import get_curator_service
    #
    #         curator = await get_curator_service()
    #         logger.info(f"Got curator service, queuing task...")
    #         task_id = await curator.queue_task(
    #             parent_session_id=session_id,
    #             trigger_type="message_done",
    #             message_count=message_count,
    #             tool_calls=tool_calls,
    #         )
    #         logger.info(f"Auto-queued curator task {task_id} for session {session_id[:8]}...")
    #
    #     except RuntimeError as e:
    #         # Curator service not initialized - skip silently
    #         logger.info(f"Curator service not available: {e}")
    #     except Exception as e:
    #         # Don't fail the main request if curator fails
    #         logger.warning(f"Failed to queue curator task: {e}", exc_info=True)

    # Note: Vault migration is now handled by the standalone script:
    # python -m scripts.migrate_vault --from /old/vault --to /new/vault
