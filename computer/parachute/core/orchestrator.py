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
from parachute.core.session_manager import SessionManager
from parachute.db.database import Database
from parachute.lib.agent_loader import build_system_prompt, load_agent, load_all_agents
from parachute.lib.context_loader import format_context_for_prompt, load_agent_context
from parachute.lib.mcp_loader import load_mcp_servers, resolve_mcp_servers
from parachute.models.agent import AgentDefinition, AgentType, create_vault_agent
from parachute.models.events import (
    AbortedEvent,
    DoneEvent,
    ErrorEvent,
    InitEvent,
    ModelEvent,
    SessionEvent,
    SessionUnavailableEvent,
    TextEvent,
    ThinkingEvent,
    ToolResultEvent,
    ToolUseEvent,
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
- **Search when helpful** - Use web search for current information, and module tools to find past conversations or journal entries

## Available Tools

- **WebSearch** - Look up current information online
- **WebFetch** - Read content from URLs

Additional tools may be available depending on which modules are connected.
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

        # For imported sessions, auto-load prior conversation for context continuity
        # This makes imported sessions "resumable" by injecting their history as context
        # Supports: Claude Code, Claude Web, ChatGPT
        effective_prior_conversation = prior_conversation
        imported_sources = (SessionSource.CLAUDE_CODE, SessionSource.CLAUDE_WEB, SessionSource.CHATGPT)
        if not prior_conversation and session.source in imported_sources:
            loaded_prior = await self.session_manager.get_prior_conversation(session)
            if loaded_prior:
                effective_prior_conversation = loaded_prior
                logger.info(f"Loaded prior conversation for {session.source.value} session: {session.id[:8]}...")
                # Force new SDK session since we're injecting context, not resuming
                is_new = True

        # Build system prompt (after loading prior conversation)
        effective_prompt = await self._build_system_prompt(
            agent=agent,
            custom_prompt=system_prompt,
            contexts=contexts,
            prior_conversation=effective_prior_conversation,
        )

        # Determine working directory
        effective_cwd = self.vault_path
        if working_directory:
            if Path(working_directory).is_absolute():
                effective_cwd = Path(working_directory)
            else:
                effective_cwd = self.vault_path / working_directory

        # Add cwd to prompt if different from vault
        if str(effective_cwd) != str(self.vault_path):
            effective_prompt += f"\n\nWorking directory: {effective_cwd}"

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

        # Handle initial context
        actual_message = message
        if initial_context and is_new:
            if not message.strip():
                actual_message = initial_context
            else:
                actual_message = f"## Context\n\n{initial_context}\n\n---\n\n## Request\n\n{message}"

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

        try:
            # Load MCP servers
            global_mcps = await load_mcp_servers(self.vault_path)
            resolved_mcps = resolve_mcp_servers(agent.mcp_servers, global_mcps)

            # Set up permission handler
            permission_handler = PermissionHandler(
                agent=agent,
                session_id=session.id,
                vault_path=str(self.vault_path),
                on_denial=lambda d: permission_denials.append(d),
            )

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

            # Use bypassPermissions mode to auto-approve ALL tool operations
            # MCP tools are trusted since they're user-configured in .mcp.json
            # File operations are trusted since we're operating within the vault
            async for event in query_streaming(
                prompt=actual_message,
                system_prompt=effective_prompt,
                cwd=effective_cwd,
                resume=resume_id,
                tools=agent.tools if agent.tools else None,
                mcp_servers=resolved_mcps,
                permission_mode="bypassPermissions",
            ):
                # Check for interrupt
                if interrupt.is_interrupted:
                    break

                event_type = event.get("type")
                logger.debug(f"SDK Event: type={event_type} keys={list(event.keys())}")

                # Capture session ID
                if event.get("session_id"):
                    captured_session_id = event["session_id"]
                    if stream_session_id is None:
                        stream_session_id = captured_session_id
                        self.active_streams[stream_session_id] = interrupt

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

            # Finalize session
            if is_new and captured_session_id:
                # Generate title from the user's first message
                title = generate_title_from_message(message) if message.strip() else None
                session = await self.session_manager.finalize_session(
                    session, captured_session_id, captured_model, title=title
                )
                logger.info(f"Finalized session: {captured_session_id[:8]}...")

            # Update message count
            if session.id != "pending":
                await self.session_manager.increment_message_count(session.id, 2)

            duration_ms = int((time.time() - start_time) * 1000)

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

    async def abort_stream(self, session_id: str) -> bool:
        """Abort an active streaming session."""
        interrupt = self.active_streams.get(session_id)
        if interrupt:
            logger.info(f"Aborting stream: {session_id[:8]}...")
            interrupt.interrupt()
            return True
        return False

    async def _build_system_prompt(
        self,
        agent: AgentDefinition,
        custom_prompt: Optional[str] = None,
        contexts: Optional[list[str]] = None,
        prior_conversation: Optional[str] = None,
    ) -> str:
        """Build the complete system prompt for an agent."""
        # Start with custom or agent prompt
        if custom_prompt:
            prompt = custom_prompt
        elif agent.system_prompt:
            prompt = agent.system_prompt
        else:
            prompt = DEFAULT_VAULT_PROMPT

        # Load specialized agents if vault agent
        if agent.name == "vault-agent":
            agents = await load_all_agents(self.vault_path)
            if agents:
                prompt += "\n\n## Specialized Agents Available\n\n"
                prompt += "You can suggest these agents for specific tasks:\n"
                for a in agents:
                    prompt += f"- {a.path}: {a.description or a.name}\n"

        # Load context files
        context_paths = contexts or ["Chat/contexts/general-context.md"]
        if agent.context:
            context_paths = agent.context.include or context_paths

        try:
            context_result = await load_agent_context(
                {"include": context_paths, "max_tokens": 50000},
                self.vault_path,
            )
            if context_result.get("content"):
                prompt += format_context_for_prompt(context_result)
        except Exception as e:
            logger.warning(f"Failed to load context: {e}")

        # Add vault location
        prompt += f"\n\n---\n\n## Environment\n\nVault location: {self.vault_path}"

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

        return prompt

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

    async def get_session_transcript(self, session_id: str) -> Optional[dict[str, Any]]:
        """
        Get the full SDK transcript for a session.

        Reads the JSONL file from ~/.claude/projects/ to get rich event history.
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

        # Parse the JSONL file
        events: list[dict[str, Any]] = []
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
                        events.append(event)

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

        return {
            "sessionId": session_id,
            "events": events,
            "model": model,
            "cwd": cwd,
            "eventCount": len(events),
        }
