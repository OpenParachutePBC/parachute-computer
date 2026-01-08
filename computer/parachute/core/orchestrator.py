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
from pathlib import Path
from typing import Any, AsyncGenerator, Optional

from parachute.config import Settings
from parachute.core.claude_sdk import query_streaming, QueryInterrupt
from parachute.core.permission_handler import PermissionHandler
from parachute.core.skills import generate_runtime_plugin, cleanup_runtime_plugin, get_skills_for_system_prompt
from parachute.core.agents import discover_agents, agents_to_sdk_format, get_agents_for_system_prompt
from parachute.core.session_manager import SessionManager
from parachute.db.database import Database
from parachute.lib.agent_loader import build_system_prompt, load_agent, load_all_agents
from parachute.lib.context_loader import format_context_for_prompt, load_agent_context
from parachute.core.context_folders import ContextFolderService
from parachute.lib.mcp_loader import load_mcp_servers, resolve_mcp_servers
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
)
from parachute.models.session import ResumeInfo, SessionSource

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
    ) -> AsyncGenerator[dict[str, Any], None]:
        """
        Run an agent with streaming response.

        This is the main entry point for chat interactions.

        Yields:
            SSE events as dictionaries
        """
        start_time = time.time()

        # Load agent
        if agent_path and agent_path != "vault-agent":
            agent = await load_agent(agent_path, self.vault_path)
            if not agent:
                yield ErrorEvent(error=f"Agent not found: {agent_path}").model_dump(by_alias=True)
                return
        else:
            agent = create_vault_agent()

        # Get or create session (before building prompt so we can load prior conversation)
        session, resume_info, is_new = await self.session_manager.get_or_create_session(
            session_id=session_id,
            module=module,
            working_directory=working_directory,
        )

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

        # Determine working directory first (needed for prompt building)
        # Priority: explicit param > session's stored value > vault path
        effective_cwd = self.vault_path
        effective_working_dir: Optional[str] = None
        if working_directory:
            effective_working_dir = working_directory
            if Path(working_directory).is_absolute():
                effective_cwd = Path(working_directory)
            else:
                effective_cwd = self.vault_path / working_directory
        elif session.working_directory:
            # Use session's stored working directory (important for imported sessions)
            effective_working_dir = session.working_directory
            effective_cwd = Path(session.working_directory)

        # Build system prompt (after loading prior conversation, with working dir)
        effective_prompt, prompt_metadata = await self._build_system_prompt(
            agent=agent,
            custom_prompt=system_prompt,
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

                    # Save to Chat/assets/YYYY-MM/
                    now = datetime.now()
                    asset_dir = self.vault_path / "Chat" / "assets" / now.strftime("%Y-%m")
                    asset_dir.mkdir(parents=True, exist_ok=True)

                    # Generate unique filename
                    timestamp = now.strftime("%Y-%m-%d_%H-%M-%S")
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
                        relative_path = f"Chat/assets/{now.strftime('%Y-%m')}/{unique_name}"

                        # Build reference for the message
                        if att_type == "image":
                            # For images, use markdown image syntax with relative path
                            # Also include absolute path for Claude to read
                            attachment_parts.append(f"![{file_name}]({relative_path})\n*(Absolute path for reading: {file_path})*")
                        elif att_type in ("text", "code"):
                            # For text/code, include content inline
                            try:
                                content = file_bytes.decode("utf-8")
                                if len(content) > 10000:
                                    content = content[:10000] + "\n...(truncated)"
                                attachment_parts.append(f"**{file_name}** ([{relative_path}]({relative_path}))\n```\n{content}\n```")
                            except UnicodeDecodeError:
                                attachment_parts.append(f"[Attached binary file: {relative_path}]({relative_path})")
                        elif att_type == "pdf":
                            # For PDFs, reference with both paths
                            attachment_parts.append(f"**{file_name}** ([{relative_path}]({relative_path}))\n*(Absolute path for reading: {file_path})*")
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
            global_mcps = await load_mcp_servers(self.vault_path, attach_tokens=True)
            resolved_mcps = resolve_mcp_servers(agent.mcp_servers, global_mcps)

            # Generate runtime plugin for skills (if any skills exist)
            plugin_dirs: list[Path] = []
            skills_plugin_dir = generate_runtime_plugin(self.vault_path)
            if skills_plugin_dir:
                plugin_dirs.append(skills_plugin_dir)
                logger.info(f"Generated skills plugin at {skills_plugin_dir}")

            # Load custom agents from .parachute/agents/
            custom_agents = discover_agents(self.vault_path)
            agents_dict = agents_to_sdk_format(custom_agents) if custom_agents else None
            if agents_dict:
                logger.info(f"Loaded {len(agents_dict)} custom agents")

            # Set up permission handler with event callbacks
            def on_permission_denial(denial: dict) -> None:
                """Track permission denials for reporting in done event."""
                permission_denials.append(denial)

            permission_handler = PermissionHandler(
                session=session,
                vault_path=str(self.vault_path),
                on_denial=on_permission_denial,
            )

            # Store handler for potential API grant/deny calls
            self.pending_permissions[session.id] = permission_handler

            # Determine resume session ID
            # Only resume if:
            # 1. Session ID is not "pending" (i.e., we have an ID)
            # 2. Not a new session (is_new=False means SDK has this session)
            # 3. Not forcing a fresh start
            resume_id = None
            if session.id != "pending" and not is_new and not force_new:
                resume_id = session.id

            logger.debug(f"Resume decision: session.id={session.id}, is_new={is_new}, force_new={force_new}, resume_id={resume_id}")

            # Run query
            current_text = ""

            # Use session-based permission handler for tool access control
            # Trust mode (default): Use bypassPermissions for backwards compatibility
            # Restricted mode: Would use can_use_tool callback (not yet supported - SDK requires AsyncIterable prompt)
            trust_mode = session.permissions.trust_mode
            logger.debug(f"Session trust_mode={trust_mode}: {session.id}")

            # TODO: Implement restricted mode with can_use_tool callback
            # Currently always using bypassPermissions regardless of trust_mode
            # Deny list enforcement would need to be added via SDK callback
            async for event in query_streaming(
                prompt=actual_message,
                system_prompt=effective_prompt,
                cwd=effective_cwd,
                resume=resume_id,
                tools=agent.tools if agent.tools else None,
                mcp_servers=resolved_mcps,
                permission_mode="bypassPermissions",
                plugin_dirs=plugin_dirs if plugin_dirs else None,
                agents=agents_dict,
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
                            session, captured_session_id, captured_model, title=title
                        )
                        session_finalized = True
                        logger.info(f"Early finalized session: {captured_session_id[:8]}...")

                        # Yield a second session event now that we have the real ID
                        # This allows the client to update its session list immediately
                        yield SessionEvent(
                            session_id=captured_session_id,
                            working_directory=working_directory,
                            resume_info=resume_info.model_dump(),
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

            # Finalize session (if not already done early)
            if is_new and captured_session_id and not session_finalized:
                # Generate title from the user's first message
                title = generate_title_from_message(message) if message.strip() else None
                session = await self.session_manager.finalize_session(
                    session, captured_session_id, captured_model, title=title
                )
                session_finalized = True
                logger.info(f"Finalized session: {captured_session_id[:8]}...")

            # Update message count
            if session.id != "pending":
                await self.session_manager.increment_message_count(session.id, 2)

            duration_ms = int((time.time() - start_time) * 1000)

            # Queue curator task for background processing BEFORE yielding done
            # (code after yield may not execute if consumer stops iterating)
            final_session_id = captured_session_id or session.id
            logger.info(f"About to queue curator: final_session_id={final_session_id}, is_pending={final_session_id == 'pending'}")
            if final_session_id and final_session_id != "pending":
                await self._queue_curator_task(
                    session_id=final_session_id,
                    message_count=session.message_count + 2,
                    context_files=contexts,
                )

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
        Build the complete system prompt for an agent.

        Returns:
            Tuple of (prompt_string, metadata_dict) for transparency
        """
        # Track metadata for transparency
        metadata: dict[str, Any] = {
            "prompt_source": "default",
            "prompt_source_path": None,
            "context_files": [],
            "context_tokens": 0,
            "context_truncated": False,
            "agent_name": agent.name,
            "available_agents": [],
            "base_prompt_tokens": 0,
            "working_directory_claude_md": None,  # Track if working dir has CLAUDE.md
        }

        # Start with custom or agent prompt
        if custom_prompt:
            prompt = custom_prompt
            metadata["prompt_source"] = "custom"
        elif agent.system_prompt and agent.name != "vault-agent":
            prompt = agent.system_prompt
            metadata["prompt_source"] = "agent"
            metadata["prompt_source_path"] = agent.path
        else:
            # Check for module-level CLAUDE.md override
            module_prompt_path = self.vault_path / "Chat" / "CLAUDE.md"
            if module_prompt_path.exists():
                try:
                    prompt = module_prompt_path.read_text(encoding="utf-8")
                    metadata["prompt_source"] = "module"
                    metadata["prompt_source_path"] = "Chat/CLAUDE.md"
                except Exception as e:
                    logger.warning(f"Failed to read module prompt: {e}")
                    prompt = DEFAULT_VAULT_PROMPT
            else:
                prompt = DEFAULT_VAULT_PROMPT

        # Estimate base prompt tokens
        metadata["base_prompt_tokens"] = len(prompt) // 4  # Rough estimate

        # Load specialized agents if vault agent
        if agent.name == "vault-agent":
            agents = await load_all_agents(self.vault_path)
            if agents:
                prompt += "\n\n## Specialized Agents Available\n\n"
                prompt += "You can suggest these agents for specific tasks:\n"
                for a in agents:
                    prompt += f"- {a.path}: {a.description or a.name}\n"
                    metadata["available_agents"].append(a.name)

        # Add available skills to prompt (discovered from .skills/)
        skills_section = get_skills_for_system_prompt(self.vault_path)
        if skills_section:
            prompt += f"\n\n{skills_section}"

        # Add custom agents to prompt (discovered from .parachute/agents/)
        agents_section = get_agents_for_system_prompt(self.vault_path)
        if agents_section:
            prompt += f"\n\n{agents_section}"

        # Load context using folder-based system
        #
        # New system: contexts are folder paths (e.g., "Projects/parachute")
        # that contain AGENTS.md files. Parent chain is auto-included.
        #
        # Backwards compatibility: file paths (e.g., "Chat/contexts/general.md")
        # are still supported via the old loader.
        #
        # Default: Always include root AGENTS.md (vault context)

        context_folder_service = ContextFolderService(self.vault_path)

        # Determine what contexts to load
        if contexts is not None:
            context_input = contexts  # Use what was provided, even if empty
        elif agent.context and agent.context.include:
            context_input = agent.context.include  # Use agent's configured contexts
        else:
            context_input = []  # Start empty, we'll add root by default

        # Separate folder paths from file paths
        folder_paths: list[str] = []
        file_paths: list[str] = []

        for ctx in context_input:
            if ctx.endswith(".md"):
                file_paths.append(ctx)
            else:
                folder_paths.append(ctx)

        # Always include root context (empty string = vault root)
        # unless explicitly providing contexts (then respect that choice)
        if not context_input and contexts is None:
            folder_paths = [""]  # Root AGENTS.md only as default

        logger.info(f"Context folders: {folder_paths}, files: {file_paths}")

        # Load folder-based context (AGENTS.md hierarchy)
        if folder_paths:
            try:
                chain = context_folder_service.build_chain(folder_paths, max_tokens=40000)
                if chain.files:
                    folder_context = context_folder_service.format_chain_for_prompt(chain)
                    prompt += f"\n\n{folder_context}"
                    metadata["context_files"].extend(chain.file_paths)
                    metadata["context_tokens"] += chain.total_tokens
                    metadata["context_truncated"] = metadata["context_truncated"] or chain.truncated
                    logger.info(f"Loaded {len(chain.files)} context files from folders ({chain.total_tokens} tokens)")
            except Exception as e:
                logger.warning(f"Failed to load folder context: {e}")

        # Load legacy file-based context (backwards compatibility)
        if file_paths:
            try:
                context_result = await load_agent_context(
                    {"include": file_paths, "max_tokens": 10000},  # Lower limit for legacy
                    self.vault_path,
                )
                if context_result.get("content"):
                    prompt += format_context_for_prompt(context_result)
                    metadata["context_files"].extend(context_result.get("files", []))
                    metadata["context_tokens"] += context_result.get("totalTokens", 0)
                    metadata["context_truncated"] = metadata["context_truncated"] or context_result.get("truncated", False)
            except Exception as e:
                logger.warning(f"Failed to load file context: {e}")

        # Check for working directory CLAUDE.md
        if working_directory:
            working_dir_path = Path(working_directory)
            # Handle both absolute paths and vault-relative paths
            if not working_dir_path.is_absolute():
                working_dir_path = self.vault_path / working_directory

            claude_md_path = working_dir_path / "CLAUDE.md"
            if claude_md_path.exists():
                try:
                    claude_md_content = claude_md_path.read_text(encoding="utf-8")
                    # Make path relative for display
                    try:
                        relative_path = claude_md_path.relative_to(self.vault_path)
                        display_path = str(relative_path)
                    except ValueError:
                        display_path = str(claude_md_path)

                    prompt += f"\n\n---\n\n## Project Context ({display_path})\n\n{claude_md_content}"
                    metadata["working_directory_claude_md"] = display_path
                    # Add tokens from CLAUDE.md to context tokens
                    claude_md_tokens = len(claude_md_content) // 4
                    metadata["context_tokens"] += claude_md_tokens
                    logger.info(f"Loaded working directory CLAUDE.md: {display_path} ({claude_md_tokens} tokens)")
                except Exception as e:
                    logger.warning(f"Failed to read working directory CLAUDE.md: {e}")

        # Add vault location and context info
        prompt += f"\n\n---\n\n## Environment\n\nVault location: {self.vault_path}"

        # Add context folders info
        if folder_paths:
            context_info = context_folder_service.format_context_folders_section(folder_paths)
            if context_info:
                prompt += f"\n\n{context_info}"

        if working_directory:
            prompt += f"\n\nWorking directory: {working_directory}"

        # Add prior conversation
        if prior_conversation:
            prompt += f"""

---

## Prior Conversation (IMPORTANT)

**The user is continuing a previous conversation they had with you (or another AI assistant).**
The messages below are from that earlier session. Treat them as if they happened in THIS conversation.

<prior_conversation>
{prior_conversation}
</prior_conversation>

The user is now continuing this conversation with you. Respond naturally as if you remember the above exchange.
"""

        # Calculate total prompt tokens
        metadata["total_prompt_tokens"] = len(prompt) // 4

        return prompt, metadata

    # =========================================================================
    # Session Management (delegated to SessionManager)
    # =========================================================================

    async def list_sessions(
        self,
        module: Optional[str] = None,
        archived: bool = False,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """List all chat sessions."""
        sessions = await self.session_manager.list_sessions(
            module=module,
            archived=archived,
            limit=limit,
        )
        return [s.model_dump(by_alias=True) for s in sessions]

    async def get_session(self, session_id: str) -> Optional[dict[str, Any]]:
        """Get a session by ID with messages."""
        session = await self.session_manager.get_session_with_messages(session_id)
        if session:
            return session.model_dump(by_alias=True)
        return None

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

        # Look for SDK session file
        projects_dir = Path.home() / ".claude" / "projects"
        if not projects_dir.exists():
            return None

        session_file = None

        # Search all project directories
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{session_id}.jsonl"
                if candidate.exists():
                    session_file = candidate
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
    # Curator Integration
    # =========================================================================

    async def _queue_curator_task(
        self,
        session_id: str,
        message_count: int,
        context_files: Optional[list[str]] = None,
    ) -> None:
        """
        Queue a curator task to run in the background.

        Called after a message completes. The curator will:
        - Update session title if needed
        - Update context files with new learnings

        This is non-blocking - the task is queued and processed asynchronously.
        """
        logger.info(f"_queue_curator_task called for session {session_id[:8]}...")
        try:
            from parachute.core.curator_service import get_curator_service

            curator = await get_curator_service()
            logger.info(f"Got curator service, queuing task...")
            task_id = await curator.queue_task(
                parent_session_id=session_id,
                trigger_type="message_done",
                message_count=message_count,
                context_files=context_files,
            )
            logger.info(f"Auto-queued curator task {task_id} for session {session_id[:8]}...")

        except RuntimeError as e:
            # Curator service not initialized - skip silently
            logger.info(f"Curator service not available: {e}")
        except Exception as e:
            # Don't fail the main request if curator fails
            logger.warning(f"Failed to queue curator task: {e}", exc_info=True)
