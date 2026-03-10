"""
Generic Daily Agent Runner.

A flexible system for running scheduled daily agents. Each agent is configured
via a markdown file in Daily/.agents/{name}.md with:
- YAML frontmatter for configuration (schedule, output path, tools, etc.)
- Markdown body for the system prompt

Agents can have custom tools and share common tools like reading journals
and chat logs. Output is written to configurable paths.
"""

import asyncio
import json
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional, Callable, Awaitable
import frontmatter

logger = logging.getLogger(__name__)


class DailyAgentState:
    """Manages state for a daily agent stored in Daily/.{agent_name}/state.json"""

    def __init__(self, vault_path: Path, agent_name: str):
        self.vault_path = vault_path
        self.agent_name = agent_name
        self.state_file = vault_path / "Daily" / f".{agent_name}" / "state.json"
        self._state: dict[str, Any] = {}

    def load(self) -> dict[str, Any]:
        """Load state from file."""
        if self.state_file.exists():
            try:
                self._state = json.loads(self.state_file.read_text())
            except json.JSONDecodeError:
                logger.warning(f"Invalid state file for {self.agent_name}, resetting")
                self._state = self._default_state()
        else:
            self._state = self._default_state()
            self.save()
        return self._state

    def save(self) -> None:
        """Save state to file."""
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(self._state, indent=2))

    def _default_state(self) -> dict[str, Any]:
        return {
            "agent": self.agent_name,
            "backend": "claude-sdk",
            "sdk_session_id": None,
            "model": None,
            "last_run_at": None,
            "last_processed_date": None,
            "run_count": 0,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

    @property
    def sdk_session_id(self) -> Optional[str]:
        return self._state.get("sdk_session_id")

    @sdk_session_id.setter
    def sdk_session_id(self, value: Optional[str]) -> None:
        self._state["sdk_session_id"] = value

    @property
    def last_processed_date(self) -> Optional[str]:
        return self._state.get("last_processed_date")

    @last_processed_date.setter
    def last_processed_date(self, value: Optional[str]) -> None:
        self._state["last_processed_date"] = value

    def record_run(self, date: str, session_id: Optional[str] = None, model: Optional[str] = None) -> None:
        """Record a successful run."""
        self._state["last_run_at"] = datetime.now(timezone.utc).isoformat()
        self._state["last_processed_date"] = date
        self._state["run_count"] = self._state.get("run_count", 0) + 1
        if session_id:
            self._state["sdk_session_id"] = session_id
        if model:
            self._state["model"] = model
        self.save()


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
        output_path: str = "Daily/{name}/{date}.md",
        tools: list[str] | None = None,
        source_file: Path | None = None,
        raw_metadata: dict[str, Any] | None = None,
        trust_level: str = "sandboxed",
    ):
        self.name = name
        self.display_name = display_name
        self.description = description
        self.system_prompt = system_prompt
        self.schedule_enabled = schedule_enabled
        self.schedule_time = schedule_time
        self.output_path = output_path
        self.tools = tools or ["read_journal", "read_chat_log", "read_recent_journals"]
        self.source_file = source_file
        self.raw_metadata = raw_metadata or {}
        self.trust_level = trust_level if trust_level in ("sandboxed", "direct") else "sandboxed"

    @classmethod
    def from_file(cls, agent_file: Path) -> Optional["DailyAgentConfig"]:
        """Load agent configuration from a markdown file."""
        if not agent_file.exists():
            return None

        try:
            post = frontmatter.loads(agent_file.read_text())
            metadata = post.metadata

            # Extract name from filename (e.g., "content-scout.md" -> "content-scout")
            name = agent_file.stem

            # Parse schedule
            schedule = metadata.get("schedule", {})
            if isinstance(schedule, str):
                schedule_enabled = True
                schedule_time = schedule
            elif isinstance(schedule, dict):
                schedule_enabled = schedule.get("enabled", True)
                schedule_time = schedule.get("time", "3:00")
            else:
                schedule_enabled = True
                schedule_time = "3:00"

            # Parse output path
            output_config = metadata.get("output", {})
            if isinstance(output_config, str):
                output_path = output_config
            elif isinstance(output_config, dict):
                output_path = output_config.get("path", f"Daily/{name}/{'{date}'}.md")
            else:
                output_path = f"Daily/{name}/{'{date}'}.md"

            return cls(
                name=name,
                display_name=metadata.get("displayName", name.replace("-", " ").title()),
                description=metadata.get("description", ""),
                system_prompt=post.content,
                schedule_enabled=schedule_enabled,
                schedule_time=schedule_time,
                output_path=output_path,
                tools=metadata.get("tools"),
                source_file=agent_file,
                raw_metadata=metadata,
                trust_level=metadata.get("trust_level", "sandboxed"),
            )

        except Exception as e:
            logger.error(f"Error loading agent config from {agent_file}: {e}")
            return None

    @classmethod
    def from_row(cls, row: dict) -> "DailyAgentConfig":
        """Build config from a Caller graph node row."""
        tools_raw = row.get("tools") or '["read_journal", "read_chat_log", "read_recent_journals"]'
        try:
            tools = json.loads(tools_raw)
        except (json.JSONDecodeError, TypeError):
            tools = ["read_journal", "read_chat_log", "read_recent_journals"]
        schedule_enabled = row.get("schedule_enabled", "true")
        if isinstance(schedule_enabled, str):
            schedule_enabled = schedule_enabled.lower() == "true"
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
        )

    def get_output_path(self, date: str) -> str:
        """Get the output file path for a specific date."""
        return self.output_path.format(name=self.name, date=date)

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


async def discover_daily_agents(vault_path: Path, graph=None) -> list[DailyAgentConfig]:
    """
    Discover all daily agents. Queries Caller nodes from the graph first;
    falls back to vault file scan if the graph is unavailable.

    Returns a list of agent configurations sorted by name.
    """
    g = graph or _get_graph()
    if g is not None:
        try:
            rows = await g.execute_cypher(
                "MATCH (c:Caller) WHERE c.enabled = 'true' RETURN c ORDER BY c.name"
            )
            agents = [DailyAgentConfig.from_row(r) for r in rows]
            logger.info(f"Discovered {len(agents)} callers from graph")
            return agents
        except Exception as e:
            logger.warning(f"Graph discovery failed, falling back to vault files: {e}")

    # Fallback: vault file scan (startup edge case before migration runs)
    agents_dir = vault_path / "Daily" / ".agents"
    if not agents_dir.exists():
        return []

    agents = []
    for agent_file in agents_dir.glob("*.md"):
        config = DailyAgentConfig.from_file(agent_file)
        if config:
            agents.append(config)
            logger.info(f"Discovered daily agent from file: {config.name} (enabled={config.schedule_enabled})")

    return sorted(agents, key=lambda a: a.name)


async def get_daily_agent_config(vault_path: Path, agent_name: str, graph=None) -> Optional[DailyAgentConfig]:
    """Get configuration for a specific daily agent. Queries graph first, falls back to vault file."""
    g = graph or _get_graph()
    if g is not None:
        try:
            rows = await g.execute_cypher(
                "MATCH (c:Caller {name: $name}) RETURN c",
                {"name": agent_name},
            )
            if rows:
                return DailyAgentConfig.from_row(rows[0])
        except Exception as e:
            logger.warning(f"Graph lookup for caller '{agent_name}' failed, falling back to vault file: {e}")

    # Fallback: vault file
    agent_file = vault_path / "Daily" / ".agents" / f"{agent_name}.md"
    return DailyAgentConfig.from_file(agent_file)


async def load_vault_mcps(vault_path: Path) -> dict[str, dict[str, Any]]:
    """
    Load MCP servers from the vault's .mcp.json.

    Only returns stdio servers since the Claude SDK doesn't support HTTP MCPs.
    """
    from parachute.lib.mcp_loader import load_mcp_servers, filter_stdio_servers

    try:
        all_servers = await load_mcp_servers(vault_path)
        stdio_servers = filter_stdio_servers(all_servers)
        logger.info(f"Loaded {len(stdio_servers)} stdio MCP servers")
        return stdio_servers
    except Exception as e:
        logger.warning(f"Failed to load vault MCPs: {e}")
        return {}


def load_user_context(vault_path: Path) -> tuple[str, str]:
    """Load user context from the vault for agent personalization."""
    user_name = "the user"
    context_text = ""

    # Legacy path — kept for users with existing context/curator.md files
    for context_path in [
        vault_path / "context" / "curator.md",
        vault_path / ".parachute" / "profile.md",
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


async def _write_initial_card(graph, agent_name: str, display_name: str, output_date: str) -> str:
    """Write an initial 'running' Card to the graph. Returns card_id."""
    card_id = f"{agent_name}:{output_date}"
    if graph is not None:
        try:
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.display_name = $display_name, "
                "    c.content = '', "
                "    c.generated_at = $generated_at, "
                "    c.status = 'running', "
                "    c.date = $date",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
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


def _build_daily_tools_mcp_config(agent_name: str) -> dict[str, Any]:
    """Build the MCP server config for daily_tools_mcp.py inside the container."""
    # The script is mounted at /workspace/daily_tools_mcp.py inside the container
    return {
        "command": "python",
        "args": ["/workspace/daily_tools_mcp.py"],
        "env": {
            "PARACHUTE_CALLER_NAME": agent_name,
            "PARACHUTE_HOST_URL": "http://host.docker.internal:3333",
        },
    }


async def _run_sandboxed(
    sandbox,
    config: DailyAgentConfig,
    system_prompt: str,
    prompt_text: str,
    state: DailyAgentState,
    card_id: str,
    date: str,
    output_date: str,
    vault_path: Path,
    graph,
) -> dict[str, Any]:
    """Run a daily agent inside a Docker sandbox container."""
    from parachute.core.sandbox import AgentSandboxConfig
    from parachute.core.capability_filter import filter_by_trust_level

    agent_name = config.name

    # Build daily tools MCP config (runs inside the container)
    daily_tools_mcp = _build_daily_tools_mcp_config(agent_name)

    # Load and filter vault MCPs for sandboxed trust level
    vault_mcps = await load_vault_mcps(vault_path)
    filtered_mcps = filter_by_trust_level(vault_mcps, "sandboxed")

    # Combine daily tools MCP with filtered vault MCPs
    all_mcp_servers = {
        f"daily_{agent_name}": daily_tools_mcp,
        **filtered_mcps,
    }

    # Slug used as both session ID (for resume) and project slug (for container)
    slug = f"caller-{agent_name}"

    # Ensure project record exists in session store
    try:
        from parachute.core.interfaces import get_registry
        session_store = get_registry().get("SessionStore")
        if session_store is not None:
            # Check if project already exists before creating
            existing = await session_store.get_project(slug)
            if not existing:
                await session_store.create_project(
                    slug=slug,
                    display_name=f"Caller: {config.display_name}",
                )
                logger.info(f"Created project record for caller '{agent_name}'")
    except Exception as e:
        logger.warning(f"Could not ensure project record for caller '{agent_name}': {e}")

    # Build sandbox config
    sandbox_config = AgentSandboxConfig(
        session_id=slug,
        agent_type="caller",
        allowed_paths=[],  # Callers get read-only vault access (default)
        network_enabled=True,  # Needs to reach host API for daily tools
        mcp_servers=all_mcp_servers,
        system_prompt=system_prompt,
        model=config.raw_metadata.get("model") or None,
        session_source=None,  # No credential injection for Callers
    )

    logger.info(
        f"Running caller '{agent_name}' in sandbox (container=parachute-env-{slug}, "
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
        # Mount the daily_tools_mcp.py script into the container
        # The sandbox run_session uses docker exec, so we need to copy the script
        # into the container's workspace on first use
        mcp_script = Path(__file__).parent.parent / "docker" / "daily_tools_mcp.py"
        if mcp_script.exists():
            # Ensure container exists first
            await sandbox.ensure_container(slug, sandbox_config)
            container_name = f"parachute-env-{slug}"

            # Copy MCP script into container
            copy_proc = await asyncio.create_subprocess_exec(
                "docker", "cp",
                str(mcp_script),
                f"{container_name}:/workspace/daily_tools_mcp.py",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await copy_proc.communicate()
            if copy_proc.returncode != 0:
                logger.warning(f"Failed to copy daily_tools_mcp.py to container: {stderr.decode()}")

        output_written = False
        captured_session_id = None
        captured_model = None

        async for event in sandbox.run_session(
            session_id=slug,
            config=sandbox_config,
            message=prompt_text,
            resume_session_id=state.sdk_session_id if state.sdk_session_id else None,
            project_slug=slug,
        ):
            event_type = event.get("type", "")

            if event_type == "session":
                captured_session_id = event.get("sessionId")
            elif event_type == "model":
                captured_model = event.get("model")
            elif event_type == "tool_use":
                tool = event.get("tool", {})
                if tool.get("name") == "write_output":
                    output_written = True
            elif event_type == "error":
                error_msg = event.get("error", "Unknown sandbox error")
                logger.error(f"Caller '{agent_name}' sandbox error: {error_msg}")
                result["status"] = "error"
                result["error"] = error_msg
                await _mark_card_failed(graph, card_id)
                return result
            elif event_type == "resume_failed":
                # Clear stale session and retry will happen via container's entrypoint
                logger.warning(
                    f"Caller '{agent_name}' resume failed, container will retry fresh"
                )
                state.sdk_session_id = None
                state.save()

        # Update state
        state.record_run(date, captured_session_id, captured_model)

        result["status"] = "completed" if output_written else "completed_no_output"
        result["sdk_session_id"] = captured_session_id
        result["model"] = captured_model
        result["output_written"] = output_written
        result["card_id"] = card_id if output_written else None
        result["journal_date"] = date

        logger.info(
            f"Caller '{agent_name}' completed (sandboxed) for {date}: "
            f"output_written={output_written}"
        )

    except Exception as e:
        logger.error(f"Caller '{agent_name}' sandbox error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)
        await _mark_card_failed(graph, card_id)

    return result


async def _run_direct(
    config: DailyAgentConfig,
    system_prompt: str,
    prompt_text: str,
    state: DailyAgentState,
    card_id: str,
    date: str,
    output_date: str,
    vault_path: Path,
    graph,
    create_tools_fn: Optional[Callable] = None,
) -> dict[str, Any]:
    """Run a daily agent directly in the server process (no Docker container)."""
    from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query
    from parachute.core.daily_agent_tools import create_daily_agent_tools

    agent_name = config.name

    # Create tools for this agent
    if create_tools_fn:
        _tools, agent_mcp_config = await create_tools_fn(vault_path, config)
    else:
        _tools, agent_mcp_config = create_daily_agent_tools(vault_path, config, graph=graph)

    # Load vault MCPs
    vault_mcps = await load_vault_mcps(vault_path)

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

    if state.sdk_session_id:
        options_kwargs["resume"] = state.sdk_session_id

    options = ClaudeAgentOptions(**options_kwargs)

    result: dict[str, Any] = {
        "status": "running",
        "agent": agent_name,
        "date": date,
        "output_date": output_date,
        "execution_mode": "direct",
        "sdk_session_id": state.sdk_session_id,
        "mcp_servers": list(all_mcp_servers.keys()),
    }

    async def run_query_with_retry(opts: ClaudeAgentOptions, retry_on_stale: bool = True):
        nonlocal state
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
                        if hasattr(block, "name") and "write_output" in str(getattr(block, "name", "")):
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
                state.sdk_session_id = None
                state.save()
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

        state.record_run(date, new_session_id, model_used)

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


async def run_daily_agent(
    vault_path: Path,
    agent_name: str,
    date: Optional[str] = None,
    force: bool = False,
    create_tools_fn: Optional[Callable[[Path, DailyAgentConfig], Awaitable[tuple[list, dict[str, Any]]]]] = None,
    build_prompt_fn: Optional[Callable[[DailyAgentConfig, str, str], str]] = None,
) -> dict[str, Any]:
    """
    Run a daily agent for a specific date.

    Routes through Docker sandbox when the Caller's trust_level is "sandboxed"
    and Docker is available. Falls back to direct (in-process) execution otherwise.

    Args:
        vault_path: Path to the vault
        agent_name: Name of the agent (e.g., "content-scout", "reflections")
        date: Date to process (YYYY-MM-DD), defaults to yesterday
        force: Run even if already processed
        create_tools_fn: Optional function to create custom tools for this agent
        build_prompt_fn: Optional function to build the user prompt

    Returns:
        Result dict with status, output path, etc.
    """
    # Load agent configuration
    config = await get_daily_agent_config(vault_path, agent_name)
    if not config:
        return {
            "status": "error",
            "error": f"Agent '{agent_name}' not found",
        }

    # Determine date - default to yesterday
    if date is None:
        now = datetime.now().astimezone()
        yesterday = now - timedelta(days=1)
        date = yesterday.strftime("%Y-%m-%d")
        output_date = now.strftime("%Y-%m-%d")
    else:
        journal_date_obj = datetime.strptime(date, "%Y-%m-%d")
        output_date_obj = journal_date_obj + timedelta(days=1)
        output_date = output_date_obj.strftime("%Y-%m-%d")

    # Load state
    state = DailyAgentState(vault_path, agent_name)
    state.load()

    # Check if already processed (unless forced)
    if not force and state.last_processed_date == date:
        return {
            "status": "skipped",
            "reason": f"Already processed {date}",
            "last_run_at": state._state.get("last_run_at"),
        }

    # Check if journal entries exist for this date in the graph
    if "read_journal" in config.tools:
        graph_for_check = _get_graph()
        if graph_for_check is not None:
            rows = await graph_for_check.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date RETURN count(e) AS cnt",
                {"date": date},
            )
            has_journal = rows and rows[0].get("cnt", 0) > 0
        else:
            has_journal = False
        if not has_journal:
            return {
                "status": "skipped",
                "reason": f"No journal found for {date}",
            }

    # Load user context and format system prompt
    user_name, user_context = load_user_context(vault_path)
    system_prompt = config.system_prompt
    if "{user_name}" in system_prompt or "{user_context}" in system_prompt:
        system_prompt = system_prompt.format(user_name=user_name, user_context=user_context)
    elif user_context:
        system_prompt = system_prompt + f"\n\n## User Context\n\n{user_context}"

    graph = _get_graph()

    # Write initial "running" Card to graph so Flutter can poll status
    card_id = await _write_initial_card(graph, agent_name, config.display_name, output_date)

    # Build the prompt
    if build_prompt_fn:
        prompt_text = build_prompt_fn(config, date, output_date)
    else:
        prompt_text = _default_prompt(config, date, output_date)

    # Route: sandboxed vs direct execution
    use_sandbox = config.trust_level == "sandboxed"
    sandbox = _get_sandbox() if use_sandbox else None

    if use_sandbox and sandbox is not None:
        # Check Docker availability
        if await sandbox.is_available() and await sandbox.image_exists():
            logger.info(f"Caller '{agent_name}' routing to sandbox (trust_level=sandboxed)")
            return await _run_sandboxed(
                sandbox=sandbox,
                config=config,
                system_prompt=system_prompt,
                prompt_text=prompt_text,
                state=state,
                card_id=card_id,
                date=date,
                output_date=output_date,
                vault_path=vault_path,
                graph=graph,
            )
        else:
            logger.warning(
                f"Caller '{agent_name}' trust_level=sandboxed but Docker unavailable, "
                f"falling back to direct execution"
            )

    # Direct execution (trust_level=direct, Docker unavailable, or no sandbox instance)
    logger.info(f"Caller '{agent_name}' running directly (trust_level={config.trust_level})")
    return await _run_direct(
        config=config,
        system_prompt=system_prompt,
        prompt_text=prompt_text,
        state=state,
        card_id=card_id,
        date=date,
        output_date=output_date,
        vault_path=vault_path,
        graph=graph,
        create_tools_fn=create_tools_fn,
    )


def _default_prompt(config: DailyAgentConfig, journal_date: str, output_date: str) -> str:
    """Build a default prompt for an agent."""
    return f"""Today is {output_date}. Please run your daily process based on yesterday ({journal_date}).

Use the tools available to you:
- `read_journal` with date "{journal_date}" to read yesterday's journal entries
- `read_chat_log` with date "{journal_date}" to read AI conversations from yesterday
- `read_recent_journals` for broader context from recent days

When you're ready, use `write_output` with date "{output_date}" to save your output.
"""
