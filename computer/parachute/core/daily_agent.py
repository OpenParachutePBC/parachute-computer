"""
Generic Daily Agent Runner.

Runs scheduled daily agents. Each Tool node in the graph holds configuration
(system_prompt, mode, scope_keys) while runtime state (last_run_at, run_count,
sdk_session_id) is derived from ToolRun records. Output is written as Card nodes.
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
# Tool state helpers — read/write runtime state via ToolRun graph nodes
# ---------------------------------------------------------------------------

async def _load_tool_state(graph: "BrainService | None", tool_name: str, memory_mode: str = "persistent") -> dict[str, Any]:
    """Derive runtime state from ToolRun queries."""
    state: dict[str, Any] = {
        "sdk_session_id": None,
        "last_run_at": None,
        "last_processed_date": None,
        "run_count": 0,
        "memory_mode": memory_mode,
    }

    try:
        # Get run count + last run
        count_rows = await graph.execute_cypher(
            "MATCH (r:ToolRun {tool_name: $name}) "
            "RETURN count(r) AS cnt, max(r.started_at) AS last_run, "
            "max(r.date) AS last_date",
            {"name": tool_name},
        )
        if count_rows and count_rows[0].get("cnt", 0) > 0:
            state["run_count"] = count_rows[0].get("cnt", 0)
            state["last_run_at"] = count_rows[0].get("last_run")
            state["last_processed_date"] = count_rows[0].get("last_date")

            # Get session_id for resume (persistent mode only)
            if memory_mode == "persistent":
                sid_rows = await graph.execute_cypher(
                    "MATCH (r:ToolRun {tool_name: $name}) "
                    "WHERE r.session_id IS NOT NULL AND r.session_id <> '' "
                    "AND r.status = 'completed' "
                    "RETURN r.session_id AS sid "
                    "ORDER BY r.started_at DESC LIMIT 1",
                    {"name": tool_name},
                )
                if sid_rows:
                    state["sdk_session_id"] = sid_rows[0].get("sid")

    except Exception as e:
        logger.warning(f"_load_tool_state failed for '{tool_name}': {e}")

    return state


async def _clear_stale_session(graph: "BrainService | None", tool_name: str) -> None:
    """Clear session_id on the latest ToolRun so next run starts fresh.

    Note: this mutates a historical ToolRun record. The session→transcript
    link for that run is lost, but this is acceptable — the alternative
    (a sentinel record) adds schema complexity for a rare edge case.
    """
    try:
        async with graph.write_lock:
            await graph.execute_cypher(
                "MATCH (r:ToolRun {tool_name: $name}) "
                "WHERE r.session_id IS NOT NULL AND r.session_id <> '' "
                "WITH r ORDER BY r.started_at DESC LIMIT 1 "
                "SET r.session_id = ''",
                {"name": tool_name},
            )
    except Exception as e:
        logger.warning(f"_clear_stale_session failed for '{tool_name}': {e}")


async def _create_tool_run(
    graph: "BrainService | None",
    run_id: str,
    tool_name: str,
    display_name: str,
    trigger_name: str,
    date: str,
    container_slug: str,
    entry_id: str = "",
    started_at: str = "",
    scope: dict[str, Any] | None = None,
) -> None:
    """Create a ToolRun node at the start of a tool invocation."""
    if graph is None:
        return
    now = started_at or datetime.now(timezone.utc).isoformat()
    scope_json = json.dumps(scope) if scope else "{}"
    try:
        async with graph.write_lock:
            await graph.execute_cypher(
                "MERGE (r:ToolRun {run_id: $run_id}) "
                "SET r.tool_name = $tool_name, "
                "    r.display_name = $display_name, "
                "    r.trigger_name = $trigger_name, "
                "    r.date = $date, "
                "    r.entry_id = $entry_id, "
                "    r.status = 'running', "
                "    r.container_slug = $container_slug, "
                "    r.scope = $scope, "
                "    r.started_at = $now, "
                "    r.created_at = $now",
                {
                    "run_id": run_id,
                    "tool_name": tool_name,
                    "display_name": display_name,
                    "trigger_name": trigger_name,
                    "date": date,
                    "entry_id": entry_id,
                    "container_slug": container_slug,
                    "scope": scope_json,
                    "now": now,
                },
            )
    except Exception as e:
        logger.warning(f"Failed to create ToolRun for '{tool_name}': {e}")



async def _complete_tool_run(
    graph: "BrainService | None",
    run_id: str,
    status: str,
    session_id: str = "",
    card_id: str = "",
    error: str = "",
    started_at: str = "",
) -> None:
    """Update a ToolRun node when the tool finishes."""
    if graph is None:
        return
    now = datetime.now(timezone.utc).isoformat()
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
                "MATCH (r:ToolRun {run_id: $run_id}) "
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
        logger.warning(f"Failed to complete ToolRun {run_id}: {e}")



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
        self.memory_mode = "persistent"  # overridable by from_tool_row

    @classmethod
    def from_tool_row(
        cls,
        tool_row: dict,
        can_call_names: list[str],
        trigger_row: dict | None = None,
    ) -> "DailyAgentConfig":
        """Build config from a Tool graph node + CAN_CALL names + optional Trigger.

        The Tool node holds the config; the Trigger holds schedule/event info;
        CAN_CALL edges hold child tool names (converted to underscore for
        TOOL_FACTORIES compat).
        """
        # Convert kebab tool names to underscore for TOOL_FACTORIES
        tools = [n.replace("-", "_") for n in can_call_names]

        # Derive schedule/trigger info from Trigger node
        schedule_enabled = False
        schedule_time = "3:00"
        trigger_event = ""
        trigger_filter: dict[str, Any] = {}
        if trigger_row:
            trigger_type = trigger_row.get("type", "")
            if trigger_type == "schedule":
                schedule_enabled = True
                schedule_time = trigger_row.get("schedule_time") or "3:00"
            elif trigger_type == "event":
                trigger_event = trigger_row.get("event") or ""
                filter_raw = trigger_row.get("event_filter") or "{}"
                try:
                    trigger_filter = json.loads(filter_raw) if isinstance(filter_raw, str) else filter_raw
                except (json.JSONDecodeError, TypeError):
                    trigger_filter = {}

        instance = cls(
            name=tool_row.get("name", ""),
            display_name=tool_row.get("display_name") or tool_row.get("name", "").replace("-", " ").title(),
            description=tool_row.get("description") or "",
            system_prompt=tool_row.get("system_prompt") or "",
            schedule_enabled=schedule_enabled,
            schedule_time=schedule_time,
            tools=tools,
            raw_metadata={"model": tool_row.get("model", "")},
            trust_level=tool_row.get("trust_level") or "sandboxed",
            trigger_event=trigger_event,
            trigger_filter=trigger_filter,
            container_slug=tool_row.get("container_slug") or "",
        )
        instance.memory_mode = tool_row.get("memory_mode") or "persistent"
        return instance

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
    """Discover all schedulable tools from Trigger→Tool graph.

    Queries schedule-type Triggers with INVOKES edges to enabled agent/transform Tools.
    """
    g = graph or _get_graph()
    if g is None:
        logger.warning("discover_daily_agents: graph unavailable, returning empty")
        return []
    try:
        rows = await g.execute_cypher(
            "MATCH (trigger:Trigger {type: 'schedule', enabled: 'true'})"
            "-[:INVOKES]->(tool:Tool {enabled: 'true'}) "
            "WHERE tool.mode = 'agent' OR tool.mode = 'transform' "
            "RETURN tool, trigger ORDER BY tool.name"
        )
        agents = []
        for row in rows:
            tool_row = row.get("tool") or row
            trigger_row = row.get("trigger") or {}
            tool_name = tool_row.get("name", "")
            # Get CAN_CALL children for this tool
            try:
                child_rows = await g.execute_cypher(
                    "MATCH (t:Tool {name: $name})-[:CAN_CALL]->(child:Tool) "
                    "RETURN child.name AS name",
                    {"name": tool_name},
                )
                can_call = [r.get("name", "") for r in child_rows]
            except Exception:
                can_call = []
            agents.append(DailyAgentConfig.from_tool_row(tool_row, can_call, trigger_row))
        logger.info(f"Discovered {len(agents)} scheduled tools from Trigger→Tool graph")
        return agents
    except Exception as e:
        logger.warning(f"Trigger→Tool discovery failed: {e}")
        return []


async def get_daily_agent_config(home_path: Path, agent_name: str, graph=None) -> Optional[DailyAgentConfig]:
    """Get configuration for a tool from the graph database."""
    g = graph or _get_graph()
    if g is None:
        return None
    try:
        tool_rows = await g.execute_cypher(
            "MATCH (t:Tool {name: $name}) RETURN t",
            {"name": agent_name},
        )
        if not tool_rows:
            return None
        tool_row = tool_rows[0]
        # Get CAN_CALL children
        try:
            child_rows = await g.execute_cypher(
                "MATCH (t:Tool {name: $name})-[:CAN_CALL]->(child:Tool) "
                "RETURN child.name AS name",
                {"name": agent_name},
            )
            can_call = [r.get("name", "") for r in child_rows]
        except Exception:
            can_call = []
        # Get trigger
        trigger_row = None
        try:
            trigger_rows = await g.execute_cypher(
                "MATCH (trigger:Trigger)-[:INVOKES]->(t:Tool {name: $name}) "
                "RETURN trigger LIMIT 1",
                {"name": agent_name},
            )
            if trigger_rows:
                trigger_row = trigger_rows[0]
        except Exception:
            pass
        return DailyAgentConfig.from_tool_row(tool_row, can_call, trigger_row)
    except Exception as e:
        logger.warning(f"Tool lookup for '{agent_name}' failed: {e}")
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

    # Resolve bridge tools: agent can narrow the default profile by declaring
    # bridge tool names in config.tools. Constrained to the profile ceiling —
    # agents cannot self-grant tools outside the fallback. (#319)
    agent_bridge_tools = frozenset(config.tools or []) & DAILY_TOOLS
    if config.tools and not agent_bridge_tools:
        logger.debug(
            f"Agent '{agent_name}' declares tools {config.tools} but none are "
            f"bridge tools — using default DAILY_TOOLS profile"
        )

    token_ctx = SandboxTokenContext(
        session_id=f"agent-{agent_name}",
        trust_level="sandboxed",
        agent_name=agent_name,
        allowed_writes=["write_output", "write_card"],
        allowed_tools=agent_bridge_tools or DAILY_TOOLS,
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
                    await _clear_stale_session(graph, agent_name)
                    agent_state["sdk_session_id"] = None

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

    # Daily agents only get their declared CAN_CALL tools — no vault MCPs.
    # This prevents automated agents from accessing browser, GitHub, etc.
    all_mcp_servers = {
        f"daily_{agent_name}": agent_mcp_config,
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
                    await _clear_stale_session(graph, agent_name)
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
    # Default to yesterday for day-scoped agents when no date is provided.
    # Day-scoped tools (read_days_notes, read_days_chats, etc.) require a date
    # in scope — if the caller didn't provide one, infer yesterday.
    date = scope.get("date", "")
    if not date and not scope.get("entry_id"):
        date = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
        scope["date"] = date
    if date:
        try:
            journal_date_obj = datetime.strptime(date, "%Y-%m-%d")
            output_date_obj = journal_date_obj + timedelta(days=1)
            output_date = output_date_obj.strftime("%Y-%m-%d")
        except ValueError:
            output_date = date
    else:
        output_date = ""

    # ── Load runtime state (from ToolRun, with Agent fallback) ───────────
    if graph is not None:
        agent_state = await _load_tool_state(graph, agent_name, config.memory_mode)
    else:
        agent_state = {"sdk_session_id": None, "last_run_at": None, "last_processed_date": None, "run_count": 0, "memory_mode": "persistent"}

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

    # ── ToolRun record ──────────────────────────────────────────────────
    container_slug = config.container_slug or f"agent-{agent_name}"
    run_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc).isoformat()
    await _create_tool_run(
        graph, run_id=run_id, tool_name=agent_name,
        display_name=config.display_name,
        trigger_name=trigger,
        date=date or scope.get("entry_date", ""),
        container_slug=container_slug,
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
        await _complete_tool_run(graph, run_id=run_id, status="failed", error=str(exc), started_at=started_at)
        raise

    # ── Record result ────────────────────────────────────────────────────
    await _complete_tool_run(
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
