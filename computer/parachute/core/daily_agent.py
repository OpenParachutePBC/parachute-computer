"""
Generic Daily Agent Runner.

Runs scheduled daily agents. Each Agent is a node in the graph database with
configuration (system_prompt, tools, schedule) and runtime state
(sdk_session_id, last_run_at, run_count). Output is written as Card nodes.
"""

import asyncio
import json
import logging
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Any, Optional, Callable, Awaitable

if TYPE_CHECKING:
    from parachute.db.brain import BrainService

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Agent state helpers — read/write runtime state on the Agent graph node
# ---------------------------------------------------------------------------

async def _load_agent_state(graph, agent_name: str) -> dict[str, Any]:
    """Load runtime state fields from the Agent graph node.

    When memory_mode is "fresh", sdk_session_id is cleared so the agent
    always starts a new conversation instead of resuming a prior one.
    """
    rows = await graph.execute_cypher(
        "MATCH (a:Agent {name: $name}) "
        "RETURN a.sdk_session_id AS sdk_session_id, "
        "       a.last_run_at AS last_run_at, "
        "       a.last_processed_date AS last_processed_date, "
        "       a.run_count AS run_count, "
        "       a.memory_mode AS memory_mode",
        {"name": agent_name},
    )
    if not rows:
        return {"sdk_session_id": None, "last_run_at": None, "last_processed_date": None, "run_count": 0, "memory_mode": "persistent"}
    row = rows[0]
    memory_mode = row.get("memory_mode") or "persistent"
    # Fresh mode — never resume a prior session
    sdk_session_id = row.get("sdk_session_id") or None
    if memory_mode == "fresh":
        sdk_session_id = None
    return {
        "sdk_session_id": sdk_session_id,
        "last_run_at": row.get("last_run_at") or None,
        "last_processed_date": row.get("last_processed_date") or None,
        "run_count": row.get("run_count") or 0,
        "memory_mode": memory_mode,
    }


async def _record_agent_run(graph, agent_name: str, date: str,
                             session_id: str | None, run_count: int,
                             memory_mode: str = "persistent") -> None:
    """Record a completed run on the Agent graph node.

    When memory_mode is "fresh", sdk_session_id is NOT persisted — this
    ensures the next run starts a new conversation rather than resuming.
    """
    now = datetime.now(timezone.utc).isoformat()
    # Fresh mode — don't persist session ID so next run starts clean
    sid = session_id or ""
    if memory_mode == "fresh":
        sid = ""
    async with graph.write_lock:
        await graph.execute_cypher(
            "MATCH (a:Agent {name: $name}) "
            "SET a.sdk_session_id = $sid, a.last_run_at = $now, "
            "    a.last_processed_date = $date, a.run_count = $rc",
            {
                "name": agent_name,
                "sid": sid,
                "now": now,
                "date": date,
                "rc": run_count + 1,
            },
        )


async def _clear_agent_session(graph, agent_name: str) -> None:
    """Clear sdk_session_id on resume failure so next run starts fresh."""
    async with graph.write_lock:
        await graph.execute_cypher(
            "MATCH (a:Agent {name: $name}) SET a.sdk_session_id = ''",
            {"name": agent_name},
        )


# ---------------------------------------------------------------------------
# AgentRun recording — observability for every agent invocation
# ---------------------------------------------------------------------------

async def _create_agent_run(
    graph: "BrainService | None",
    run_id: str,
    agent_name: str,
    display_name: str,
    date: str,
    trigger: str,
    container_slug: str,
    entry_id: str = "",
    started_at: str = "",
    scope: dict[str, Any] | None = None,
) -> None:
    """Create an AgentRun node at the start of an agent invocation."""
    if graph is None:
        return
    now = started_at or datetime.now(timezone.utc).isoformat()
    scope_json = json.dumps(scope) if scope else "{}"
    try:
        async with graph.write_lock:
            await graph.execute_cypher(
                "MERGE (r:AgentRun {run_id: $run_id}) "
                "SET r.agent_name = $agent_name, "
                "    r.display_name = $display_name, "
                "    r.date = $date, "
                "    r.entry_id = $entry_id, "
                "    r.trigger = $trigger, "
                "    r.status = 'running', "
                "    r.container_slug = $container_slug, "
                "    r.scope = $scope, "
                "    r.started_at = $now",
                {
                    "run_id": run_id,
                    "agent_name": agent_name,
                    "display_name": display_name,
                    "date": date,
                    "entry_id": entry_id,
                    "trigger": trigger,
                    "container_slug": container_slug,
                    "scope": scope_json,
                    "now": now,
                },
            )
    except Exception as e:
        logger.warning(f"Failed to create AgentRun for '{agent_name}': {e}")


async def _complete_agent_run(
    graph: "BrainService | None",
    run_id: str,
    status: str,
    session_id: str = "",
    card_id: str = "",
    error: str = "",
    started_at: str = "",
) -> None:
    """Update an AgentRun node when the agent finishes (success or failure)."""
    if graph is None:
        return
    now = datetime.now(timezone.utc).isoformat()
    # Calculate duration if we have a start time
    duration = 0.0
    if started_at:
        try:
            start = datetime.fromisoformat(started_at)
            end = datetime.fromisoformat(now)
            duration = (end - start).total_seconds()
        except (ValueError, TypeError):
            pass
    try:
        async with graph.write_lock:
            await graph.execute_cypher(
                "MATCH (r:AgentRun {run_id: $run_id}) "
                "SET r.status = $status, "
                "    r.session_id = $session_id, "
                "    r.card_id = $card_id, "
                "    r.error = $error, "
                "    r.completed_at = $now, "
                "    r.duration_seconds = $duration",
                {
                    "run_id": run_id,
                    "status": status,
                    "session_id": session_id,
                    "card_id": card_id,
                    "error": error,
                    "now": now,
                    "duration": duration,
                },
            )
    except Exception as e:
        logger.warning(f"Failed to complete AgentRun {run_id}: {e}")


class DailyAgentConfig:
    """Configuration for a daily agent loaded from its markdown file."""

    def __init__(
        self,
        name: str,
        display_name: str,
        description: str,
        system_prompt: str,
        schedule_enabled: bool = True,
        schedule_time: str = "3:00",
        tools: list[str] | None = None,
        raw_metadata: dict[str, Any] | None = None,
        trust_level: str = "sandboxed",
        trigger_event: str = "",
        trigger_filter: dict[str, Any] | None = None,
        container_slug: str = "",
    ):
        self.name = name
        self.display_name = display_name
        self.description = description
        self.system_prompt = system_prompt
        self.schedule_enabled = schedule_enabled
        self.schedule_time = schedule_time
        self.tools = tools or ["read_days_notes", "read_days_chats", "read_recent_journals"]
        self.raw_metadata = raw_metadata or {}
        self.trust_level = trust_level if trust_level in ("sandboxed", "direct") else "sandboxed"
        self.trigger_event = trigger_event
        self.trigger_filter = trigger_filter or {}
        self.container_slug = container_slug  # empty = use default agent-{name}

    @classmethod
    def from_row(cls, row: dict) -> "DailyAgentConfig":
        """Build config from an Agent graph node row."""
        tools_raw = row.get("tools") or '["read_days_notes", "read_days_chats", "read_recent_journals"]'
        try:
            tools = json.loads(tools_raw)
        except (json.JSONDecodeError, TypeError):
            tools = ["read_days_notes", "read_days_chats", "read_recent_journals"]
        schedule_enabled = row.get("schedule_enabled", "true")
        if isinstance(schedule_enabled, str):
            schedule_enabled = schedule_enabled.lower() == "true"
        # Parse trigger_filter JSON
        trigger_filter_raw = row.get("trigger_filter") or "{}"
        try:
            trigger_filter = json.loads(trigger_filter_raw) if isinstance(trigger_filter_raw, str) else trigger_filter_raw
        except (json.JSONDecodeError, TypeError):
            trigger_filter = {}

        return cls(
            name=row["name"],
            display_name=row.get("display_name") or row["name"].replace("-", " ").title(),
            description=row.get("description") or "",
            system_prompt=row.get("system_prompt") or "",
            schedule_enabled=schedule_enabled,
            schedule_time=row.get("schedule_time") or "3:00",
            tools=tools,
            raw_metadata={"model": row.get("model", "")},
            trust_level=row.get("trust_level") or "sandboxed",
            trigger_event=row.get("trigger_event") or "",
            trigger_filter=trigger_filter,
            container_slug=row.get("container_slug") or "",
        )

    def get_schedule_hour_minute(self) -> tuple[int, int]:
        """Parse schedule time into (hour, minute)."""
        try:
            parts = self.schedule_time.strip().split(":")
            hour = int(parts[0])
            minute = int(parts[1]) if len(parts) > 1 else 0
            return (hour % 24, minute % 60)
        except (ValueError, IndexError):
            logger.warning(f"Invalid time format '{self.schedule_time}', using default 3:00")
            return (3, 0)


def _get_graph() -> Any | None:
    """Get BrainDB from the service registry, or None if unavailable."""
    try:
        from parachute.core.interfaces import get_registry
        return get_registry().get("BrainDB")
    except Exception:
        return None


async def discover_daily_agents(home_path: Path, graph=None) -> list[DailyAgentConfig]:
    """Discover all enabled Agents from the graph database.

    Returns a list of agent configurations sorted by name, or empty if graph
    is unavailable.
    """
    g = graph or _get_graph()
    if g is None:
        logger.warning("discover_daily_agents: graph unavailable, returning empty")
        return []
    try:
        rows = await g.execute_cypher(
            "MATCH (a:Agent) WHERE a.enabled = 'true' RETURN a ORDER BY a.name"
        )
        agents = [DailyAgentConfig.from_row(r) for r in rows]
        logger.info(f"Discovered {len(agents)} agents from graph")
        return agents
    except Exception as e:
        logger.warning(f"Graph discovery failed: {e}")
        return []


async def get_daily_agent_config(home_path: Path, agent_name: str, graph=None) -> Optional[DailyAgentConfig]:
    """Get configuration for a specific Agent from the graph database."""
    g = graph or _get_graph()
    if g is None:
        return None
    try:
        rows = await g.execute_cypher(
            "MATCH (a:Agent {name: $name}) RETURN a",
            {"name": agent_name},
        )
        if rows:
            return DailyAgentConfig.from_row(rows[0])
    except Exception as e:
        logger.warning(f"Graph lookup for agent '{agent_name}' failed: {e}")
    return None


async def load_user_mcps(home_path: Path) -> dict[str, dict[str, Any]]:
    """
    Load stdio MCP servers from the vault's .mcp.json.

    Used by direct-mode (non-sandboxed) agents. Filters to stdio-only since
    direct agents run in-process and don't need the HTTP MCP bridge.
    """
    from parachute.lib.mcp_loader import load_mcp_servers, filter_stdio_servers

    try:
        all_servers = await load_mcp_servers(home_path)
        stdio_servers = filter_stdio_servers(all_servers)
        logger.info(f"Loaded {len(stdio_servers)} stdio MCP servers")
        return stdio_servers
    except Exception as e:
        logger.warning(f"Failed to load vault MCPs: {e}")
        return {}


def load_user_context(home_path: Path) -> tuple[str, str]:
    """Load user context from the vault for agent personalization."""
    user_name = "the user"
    context_text = ""

    # Legacy path — kept for users with existing context/curator.md files
    for context_path in [
        home_path / "context" / "curator.md",
        home_path / ".parachute" / "profile.md",
    ]:
        if context_path.exists():
            try:
                content = context_path.read_text(encoding="utf-8")
                context_text = content
                # Try to extract name
                for line in content.split("\n"):
                    if "**Name**:" in line:
                        user_name = line.split("**Name**:")[-1].strip().split()[0]
                        break
                    elif line.startswith("# "):
                        user_name = line[2:].strip()
                        break
                break
            except Exception as e:
                logger.warning(f"Failed to load user context from {context_path}: {e}")

    return user_name, context_text


def _get_sandbox() -> Any | None:
    """Get DockerSandbox from the service registry, or None if unavailable."""
    try:
        from parachute.core.interfaces import get_registry
        return get_registry().get("DockerSandbox")
    except Exception:
        return None


async def _write_initial_card(
    graph, agent_name: str, display_name: str, output_date: str, card_type: str = "default",
) -> str:
    """Write an initial 'running' Card to the graph. Returns card_id."""
    card_id = f"{agent_name}:{card_type}:{output_date}"
    if graph is not None:
        try:
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.card_type = $card_type, "
                "    c.display_name = $display_name, "
                "    c.content = '', "
                "    c.generated_at = $generated_at, "
                "    c.status = 'running', "
                "    c.date = $date, "
                "    c.read_at = ''",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
                    "card_type": card_type,
                    "display_name": display_name,
                    "generated_at": datetime.now(timezone.utc).isoformat(),
                    "date": output_date,
                },
            )
        except Exception as e:
            logger.warning(f"Could not write initial running card for '{agent_name}': {e}")
    return card_id


async def _mark_card_failed(graph, card_id: str) -> None:
    """Mark a Card as failed in the graph."""
    if graph is not None:
        try:
            await graph.execute_cypher(
                "MATCH (c:Card {card_id: $card_id}) SET c.status = 'failed'",
                {"card_id": card_id},
            )
        except Exception:
            pass


def _build_http_mcp_config(token: str) -> dict[str, Any]:
    """Build HTTP MCP server config pointing to the host's MCP bridge."""
    from parachute.api.mcp_bridge import build_http_mcp_config
    return build_http_mcp_config(token)


async def _run_sandboxed(
    sandbox,
    config: DailyAgentConfig,
    system_prompt: str,
    prompt_text: str,
    agent_state: dict[str, Any],
    card_id: str,
    date: str,
    output_date: str,
    home_path: Path,
    graph,
) -> dict[str, Any]:
    """Run a daily agent inside a Docker sandbox container."""
    from parachute.core.sandbox import AgentSandboxConfig

    agent_name = config.name

    # Create a sandbox token for this agent session
    from parachute.core.interfaces import get_registry
    from parachute.lib.sandbox_tokens import SandboxTokenContext

    token_store = get_registry().get("SandboxTokenStore")
    if token_store is None:
        raise RuntimeError(
            f"SandboxTokenStore not available — cannot run agent '{agent_name}' "
            f"in sandbox without MCP tools"
        )

    # Container slug is persistent and human-readable; session ID is per-run UUID.
    # The container slug identifies the Docker environment; the session ID identifies
    # the SDK transcript for this specific run.
    container_slug = config.container_slug or f"agent-{agent_name}"
    run_session_id = str(uuid.uuid4())

    from parachute.api.mcp_tools import DAILY_TOOLS

    token_ctx = SandboxTokenContext(
        session_id=f"agent-{agent_name}",
        trust_level="sandboxed",
        agent_name=agent_name,
        allowed_writes=["write_output", "write_card"],
        allowed_tools=DAILY_TOOLS,
    )
    sandbox_token = token_store.create_token(token_ctx)

    # Build HTTP MCP config pointing to host's MCP bridge
    mcp_config = _build_http_mcp_config(sandbox_token)
    all_mcp_servers = {"parachute": mcp_config}

    # Ensure container record exists in session store.
    # If the agent targets a user-configured container, validate it exists.
    is_custom_container = bool(config.container_slug)
    try:
        from parachute.core.interfaces import get_registry
        session_store = get_registry().get("ChatStore")
        if session_store is not None:
            existing = await session_store.get_container(container_slug)
            if not existing:
                if is_custom_container:
                    # User configured a specific container that doesn't exist
                    raise RuntimeError(
                        f"Container '{container_slug}' not found — "
                        f"create it or clear the agent's container setting"
                    )
                # Auto-create dedicated container for this agent
                await session_store.create_container(
                    slug=container_slug,
                    display_name=f"Agent: {config.display_name}",
                )
                logger.info(f"Created container record for agent '{agent_name}'")
    except RuntimeError:
        raise  # Re-raise validation errors
    except Exception as e:
        logger.warning(f"Could not ensure container record for agent '{agent_name}': {e}")

    # Build sandbox config — session_id is the per-run UUID (CLI requires UUID format)
    sandbox_config = AgentSandboxConfig(
        session_id=run_session_id,
        agent_type="agent",
        allowed_paths=[],  # Agents get read-only vault access (default)
        network_enabled=True,  # Needs to reach host API for daily tools
        mcp_servers=all_mcp_servers,
        system_prompt=system_prompt,
        use_preset=False,  # Agents don't need Claude Code preset
        model=config.raw_metadata.get("model") or None,
        session_source=None,  # No credential injection for agents
    )

    logger.info(
        f"Running agent '{agent_name}' in sandbox (container=parachute-env-{container_slug}, "
        f"mcps={list(all_mcp_servers.keys())})"
    )

    result: dict[str, Any] = {
        "status": "running",
        "agent": agent_name,
        "date": date,
        "output_date": output_date,
        "execution_mode": "sandboxed",
        "mcp_servers": list(all_mcp_servers.keys()),
    }

    try:
        output_written = False
        captured_session_id = None
        captured_model = None

        async for event in sandbox.run_session(
            session_id=run_session_id,
            config=sandbox_config,
            message=prompt_text,
            resume_session_id=agent_state["sdk_session_id"] if agent_state["sdk_session_id"] else None,
            container_slug=container_slug,
        ):
            event_type = event.get("type", "")

            if event_type == "session":
                captured_session_id = event.get("sessionId")
            elif event_type == "model":
                captured_model = event.get("model")
            elif event_type == "tool_use":
                tool = event.get("tool", {})
                tool_name = tool.get("name", "")
                # Tool name may be bare or MCP-prefixed (mcp__parachute__write_card)
                if tool_name in ("write_output", "write_card") or tool_name.endswith(("__write_output", "__write_card")):
                    output_written = True
            elif event_type == "error":
                error_msg = event.get("error", "Unknown sandbox error")
                logger.error(f"Agent '{agent_name}' sandbox error: {error_msg}")
                result["status"] = "error"
                result["error"] = error_msg
                await _mark_card_failed(graph, card_id)
                return result
            elif event_type == "resume_failed":
                # Clear stale session and retry will happen via container's entrypoint
                logger.warning(
                    f"Agent '{agent_name}' resume failed, container will retry fresh"
                )
                if graph is not None:
                    await _clear_agent_session(graph, agent_name)
                    agent_state["sdk_session_id"] = None

        # Update state on Agent graph node
        if graph is not None:
            await _record_agent_run(graph, agent_name, date, captured_session_id, agent_state["run_count"], agent_state.get("memory_mode", "persistent"))

        result["status"] = "completed" if output_written else "completed_no_output"
        result["sdk_session_id"] = captured_session_id
        result["model"] = captured_model
        result["output_written"] = output_written
        result["card_id"] = card_id if output_written else None
        result["journal_date"] = date

        logger.info(
            f"Agent '{agent_name}' completed (sandboxed) for {date}: "
            f"output_written={output_written}"
        )

    except Exception as e:
        logger.error(f"Agent '{agent_name}' sandbox error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)
        await _mark_card_failed(graph, card_id)
    finally:
        # Revoke sandbox token after run completes
        if sandbox_token and token_store is not None:
            token_store.revoke_token(sandbox_token)

    return result


async def _run_direct(
    config: DailyAgentConfig,
    system_prompt: str,
    prompt_text: str,
    agent_state: dict[str, Any],
    card_id: str,
    date: str,
    output_date: str,
    home_path: Path,
    graph,
    create_tools_fn: Optional[Callable] = None,
) -> dict[str, Any]:
    """Run a daily agent directly in the server process (no Docker container)."""
    from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query
    from parachute.core.daily_agent_tools import create_daily_agent_tools

    agent_name = config.name

    # Create tools for this agent
    if create_tools_fn:
        _tools, agent_mcp_config = await create_tools_fn(home_path, config)
    else:
        _tools, agent_mcp_config = create_daily_agent_tools(home_path, config, graph=graph)

    # Load vault MCPs
    vault_mcps = await load_user_mcps(home_path)

    # Combine all MCP servers
    all_mcp_servers = {
        f"daily_{agent_name}": agent_mcp_config,
        **vault_mcps,
    }

    logger.info(f"Running agent '{agent_name}' directly with MCPs: {list(all_mcp_servers.keys())}")

    # Wrap prompt in async generator with delay
    async def generate_prompt():
        await asyncio.sleep(1.0)
        yield {"type": "user", "message": {"role": "user", "content": prompt_text}}

    # Build options
    options_kwargs = {
        "system_prompt": system_prompt,
        "max_turns": 20,
        "mcp_servers": all_mcp_servers,
        "permission_mode": "bypassPermissions",
        "stderr": lambda msg: logger.error(f"CLI STDERR: {msg}"),
        "debug_stderr": sys.stderr,
    }

    if agent_state["sdk_session_id"]:
        options_kwargs["resume"] = agent_state["sdk_session_id"]

    options = ClaudeAgentOptions(**options_kwargs)

    result: dict[str, Any] = {
        "status": "running",
        "agent": agent_name,
        "date": date,
        "output_date": output_date,
        "execution_mode": "direct",
        "sdk_session_id": agent_state["sdk_session_id"],
        "mcp_servers": list(all_mcp_servers.keys()),
    }

    async def run_query_with_retry(opts: ClaudeAgentOptions, retry_on_stale: bool = True):
        try:
            response_text = ""
            new_session_id = None
            model_used = None
            output_written = False

            async for event in sdk_query(prompt=generate_prompt(), options=opts):
                if hasattr(event, "session_id") and event.session_id:
                    new_session_id = event.session_id
                if hasattr(event, "model") and event.model:
                    model_used = event.model
                if hasattr(event, "content"):
                    for block in event.content:
                        if hasattr(block, "text"):
                            response_text += block.text
                        block_name = str(getattr(block, "name", ""))
                        if hasattr(block, "name") and ("write_output" in block_name or "write_card" in block_name):
                            output_written = True

            return {
                "success": True,
                "response_text": response_text,
                "new_session_id": new_session_id,
                "model_used": model_used,
                "output_written": output_written,
            }

        except Exception as e:
            error_str = str(e).lower()
            if retry_on_stale and ("no conversation found" in error_str or "session" in error_str and "not found" in error_str):
                logger.warning(
                    f"Agent '{agent_name}' session expired (id={opts.resume}), "
                    "clearing and retrying with fresh session"
                )
                if graph is not None:
                    await _clear_agent_session(graph, agent_name)
                    agent_state["sdk_session_id"] = None
                fresh_opts_kwargs = {
                    "system_prompt": opts.system_prompt,
                    "max_turns": opts.max_turns,
                    "mcp_servers": opts.mcp_servers,
                    "permission_mode": opts.permission_mode,
                }
                fresh_opts = ClaudeAgentOptions(**fresh_opts_kwargs)
                return await run_query_with_retry(fresh_opts, retry_on_stale=False)
            raise

    try:
        query_result = await run_query_with_retry(options)

        new_session_id = query_result["new_session_id"]
        model_used = query_result["model_used"]
        output_written = query_result["output_written"]

        if graph is not None:
            await _record_agent_run(graph, agent_name, date, new_session_id, agent_state["run_count"], agent_state.get("memory_mode", "persistent"))

        result["status"] = "completed" if output_written else "completed_no_output"
        result["sdk_session_id"] = new_session_id
        result["model"] = model_used
        result["output_written"] = output_written
        result["card_id"] = card_id if output_written else None
        result["journal_date"] = date
        result["output_date"] = output_date

        logger.info(f"Agent '{agent_name}' completed (direct) for {date}: output_written={output_written}")

    except Exception as e:
        logger.error(f"Agent '{agent_name}' error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)
        await _mark_card_failed(graph, card_id)

    return result


async def run_agent(
    home_path: Path,
    agent_name: str,
    scope: dict[str, Any],
    force: bool = False,
    trigger: str = "manual",
) -> dict[str, Any]:
    """
    Unified agent runner. Takes an agent name and a scope dict.

    Scope is plain data that determines how tools get bound:
    - {"date": "2026-03-22"} → day-scoped (process-day, scheduled)
    - {"entry_id": "abc", "event": "note.transcription_complete"} → note-scoped (process-note, triggered)
    - Can carry both keys for agents that mix scopes.

    Pre-checks, tool creation, and prompt building are driven by scope keys.
    Execution routes through sandbox or direct based on config.trust_level.

    Args:
        home_path: Path to the vault
        agent_name: Name of the agent
        scope: Dict of scope data (date, entry_id, event, etc.)
        force: Run even if already processed
        trigger: How the run was initiated ("scheduled", "event", "manual")

    Returns:
        Result dict with status, agent, run_id, etc.
    """
    from parachute.core.agent_tools import bind_tools

    # Load agent configuration
    config = await get_daily_agent_config(home_path, agent_name)
    if not config:
        return {"status": "error", "agent": agent_name, "error": f"Agent '{agent_name}' not found"}

    graph = _get_graph()

    # ── Resolve date / output_date ────────────────────────────────────────
    date = scope.get("date", "")
    if date:
        try:
            journal_date_obj = datetime.strptime(date, "%Y-%m-%d")
            output_date_obj = journal_date_obj + timedelta(days=1)
            output_date = output_date_obj.strftime("%Y-%m-%d")
        except ValueError:
            output_date = date
    else:
        output_date = ""

    # ── Load runtime state ────────────────────────────────────────────────
    if graph is not None:
        agent_state = await _load_agent_state(graph, agent_name)
    else:
        agent_state = {"sdk_session_id": None, "last_run_at": None, "last_processed_date": None, "run_count": 0}

    # ── Pre-checks (driven by scope keys) ─────────────────────────────────

    # Date-based dedup
    if date and not force and agent_state["last_processed_date"] == date:
        return {"status": "skipped", "reason": f"Already processed {date}", "last_run_at": agent_state["last_run_at"]}

    # Check notes exist for date (if agent reads day's notes)
    day_read_tools = {"read_days_notes", "read_journal"}
    if date and day_read_tools & set(config.tools):
        if graph is not None:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date RETURN count(e) AS cnt",
                {"date": date},
            )
            has_notes = rows and rows[0].get("cnt", 0) > 0
        else:
            has_notes = False
        if not has_notes:
            return {"status": "skipped", "reason": f"No notes found for {date}"}

    # Check entry exists (if agent processes a specific note)
    entry_id = scope.get("entry_id", "")
    if entry_id:
        if graph is None:
            return {"status": "error", "agent": agent_name, "error": "BrainDB unavailable"}
        rows = await graph.execute_cypher(
            "MATCH (e:Note {entry_id: $entry_id}) RETURN e.entry_type AS entry_type, e.date AS date",
            {"entry_id": entry_id},
        )
        if not rows:
            return {"status": "error", "agent": agent_name, "entry_id": entry_id, "error": f"Entry '{entry_id}' not found"}
        # Enrich scope with entry metadata for prompt building
        scope.setdefault("entry_type", rows[0].get("entry_type") or "text")
        scope.setdefault("entry_date", rows[0].get("date") or "")

    # ── Build system prompt ───────────────────────────────────────────────
    user_name, user_context = load_user_context(home_path)
    system_prompt = config.system_prompt
    if "{user_name}" in system_prompt or "{user_context}" in system_prompt:
        system_prompt = system_prompt.format(user_name=user_name, user_context=user_context)
    elif user_context:
        system_prompt = system_prompt + f"\n\n## User Context\n\n{user_context}"

    # ── Build user prompt (scope-driven) ──────────────────────────────────
    if entry_id:
        # Note-scoped prompt
        event = scope.get("event", "")
        event_desc = {
            "note.created": "created",
            "note.transcription_complete": "transcribed (voice transcription completed)",
        }.get(event, event.replace("note.", "").replace("_", " ") if event else "ready for processing")
        entry_type = scope.get("entry_type", "text")
        entry_date = scope.get("entry_date", "")
        prompt_text = (
            f"A note has been {event_desc}. Use your tools to process it.\n\n"
            f"Entry ID: {entry_id}\n"
            f"Entry type: {entry_type}\n"
            f"Date: {entry_date}\n\n"
            f"Start by using `read_this_note` to read the note's content, then process it "
            f"according to your instructions."
        )
    elif date:
        # Day-scoped prompt
        prompt_text = _default_prompt(config, date, output_date)
    else:
        prompt_text = "Process according to your instructions."

    # ── Create tools via bind_tools ───────────────────────────────────────
    # Add display_name to scope for write_card
    scope.setdefault("display_name", config.display_name)

    async def _create_tools_fn(vp, cfg):
        return bind_tools(
            tool_names=cfg.tools,
            scope=scope,
            graph=graph,
            agent_name=cfg.name,
            home_path=vp,
        )

    # ── Write initial Card (only if agent writes cards) ───────────────────
    card_id = ""
    if "write_card" in config.tools and output_date:
        card_id = await _write_initial_card(graph, agent_name, config.display_name, output_date)

    # ── AgentRun record ───────────────────────────────────────────────────
    container_slug = config.container_slug or f"agent-{agent_name}"
    run_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc).isoformat()
    await _create_agent_run(
        graph, run_id=run_id, agent_name=agent_name,
        display_name=config.display_name, date=date or scope.get("entry_date", ""),
        trigger=trigger, container_slug=container_slug,
        entry_id=entry_id, started_at=started_at, scope=scope,
    )

    logger.info(
        f"Running agent '{agent_name}' (trigger={trigger}, "
        f"scope_keys={list(scope.keys())}, tools={config.tools})"
    )

    # ── Route execution ───────────────────────────────────────────────────
    use_sandbox = config.trust_level == "sandboxed"
    sandbox = _get_sandbox() if use_sandbox else None
    result: dict[str, Any] | None = None

    try:
        if use_sandbox and sandbox is not None:
            if await sandbox.is_available() and await sandbox.image_exists():
                logger.info(f"Agent '{agent_name}' routing to sandbox")
                result = await _run_sandboxed(
                    sandbox=sandbox,
                    config=config,
                    system_prompt=system_prompt,
                    prompt_text=prompt_text,
                    agent_state=agent_state,
                    card_id=card_id,
                    date=date or scope.get("entry_date", ""),
                    output_date=output_date or date,
                    home_path=home_path,
                    graph=graph,
                )
            else:
                logger.warning(
                    f"Agent '{agent_name}' trust_level=sandboxed but Docker unavailable, "
                    f"falling back to direct execution"
                )

        if result is None:
            logger.info(f"Agent '{agent_name}' running directly (trust_level={config.trust_level})")
            result = await _run_direct(
                config=config,
                system_prompt=system_prompt,
                prompt_text=prompt_text,
                agent_state=agent_state,
                card_id=card_id,
                date=date or scope.get("entry_date", ""),
                output_date=output_date or date,
                home_path=home_path,
                graph=graph,
                create_tools_fn=_create_tools_fn,
            )
    except Exception as exc:
        logger.error(f"Agent '{agent_name}' execution failed: {exc}", exc_info=True)
        await _complete_agent_run(graph, run_id=run_id, status="failed", error=str(exc), started_at=started_at)
        raise

    # ── Record result ─────────────────────────────────────────────────────
    await _complete_agent_run(
        graph, run_id=run_id,
        status=result.get("status", "unknown"),
        session_id=result.get("sdk_session_id", ""),
        card_id=result.get("card_id", "") or "",
        error=result.get("error", ""),
        started_at=started_at,
    )
    result["run_id"] = run_id

    # Annotate result with scope info
    if entry_id:
        result["entry_id"] = entry_id
        result["event"] = scope.get("event", "")
        result["execution_type"] = "triggered"

    return result


# ---------------------------------------------------------------------------
# Backwards-compatible wrappers (callers don't need to change)
# ---------------------------------------------------------------------------


async def run_daily_agent(
    home_path: Path,
    agent_name: str,
    date: Optional[str] = None,
    force: bool = False,
    trigger: str = "manual",
) -> dict[str, Any]:
    """Run a day-scoped agent. Thin wrapper around run_agent()."""
    if date is None:
        now = datetime.now().astimezone()
        yesterday = now - timedelta(days=1)
        date = yesterday.strftime("%Y-%m-%d")

    return await run_agent(home_path, agent_name, {"date": date}, force=force, trigger=trigger)


def _default_prompt(config: DailyAgentConfig, journal_date: str, output_date: str) -> str:
    """Build a default prompt for an agent.

    NOTE: The date is stated explicitly and redundantly because agents with
    persistent memory resume a prior SDK session that may carry stale date
    references from a previous run. The triple-emphasis ensures the model
    uses the correct date.
    """
    try:
        jd = datetime.strptime(journal_date, "%Y-%m-%d")
        day_name = jd.strftime("%A")  # e.g. "Monday"
        date_label = f"{day_name}, {journal_date}"
    except ValueError:
        date_label = journal_date

    return f"""IMPORTANT — This run is for **{date_label}**. Ignore any dates from prior conversations.

Today's date is {output_date}. Reflect on the journal entries from yesterday, {date_label}.

Use the tools available to you:
- `read_days_notes` with date "{journal_date}" to read the journal entries from {date_label}
- `read_days_chats` with date "{journal_date}" to read AI conversations from {date_label}
- `read_recent_journals` for broader context from recent days

When you're ready, use `write_card` with date "{output_date}" to save your output.
"""


# ---------------------------------------------------------------------------
# Triggered Agent execution — runs an Agent on a specific Note
# ---------------------------------------------------------------------------

async def run_triggered_agent(
    home_path: Path,
    agent_name: str,
    entry_id: str,
    event: str,
) -> dict[str, Any]:
    """Run a note-scoped triggered agent. Thin wrapper around run_agent()."""
    return await run_agent(
        home_path, agent_name,
        {"entry_id": entry_id, "event": event},
        trigger="event",
    )
