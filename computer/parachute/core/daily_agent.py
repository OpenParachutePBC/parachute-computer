"""
Generic Daily Agent Runner.

A flexible system for running scheduled daily agents. Each agent is configured
via a markdown file in Daily/.agents/{name}.md with:
- YAML frontmatter for configuration (schedule, output path, tools, etc.)
- Markdown body for the system prompt

Agents can have custom tools and share common tools like reading journals
and chat logs. Output is written to configurable paths.
"""

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

    @classmethod
    def from_file(cls, agent_file: Path) -> Optional["DailyAgentConfig"]:
        """Load agent configuration from a markdown file."""
        if not agent_file.exists():
            return None

        try:
            post = frontmatter.loads(agent_file.read_text())
            metadata = post.metadata

            # Extract name from filename (e.g., "curator.md" -> "curator")
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
            )

        except Exception as e:
            logger.error(f"Error loading agent config from {agent_file}: {e}")
            return None

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


def discover_daily_agents(vault_path: Path) -> list[DailyAgentConfig]:
    """
    Discover all daily agents configured in Daily/.agents/.

    Returns a list of agent configurations sorted by name.
    """
    agents_dir = vault_path / "Daily" / ".agents"
    if not agents_dir.exists():
        return []

    agents = []
    for agent_file in agents_dir.glob("*.md"):
        config = DailyAgentConfig.from_file(agent_file)
        if config:
            agents.append(config)
            logger.info(f"Discovered daily agent: {config.name} (enabled={config.schedule_enabled})")

    return sorted(agents, key=lambda a: a.name)


def get_daily_agent_config(vault_path: Path, agent_name: str) -> Optional[DailyAgentConfig]:
    """Get configuration for a specific daily agent."""
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

    # Try to load from context/curator.md or .parachute/profile.md
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

    Args:
        vault_path: Path to the vault
        agent_name: Name of the agent (e.g., "curator", "content-scout")
        date: Date to process (YYYY-MM-DD), defaults to yesterday
        force: Run even if already processed
        create_tools_fn: Optional function to create custom tools for this agent
        build_prompt_fn: Optional function to build the user prompt

    Returns:
        Result dict with status, output path, etc.
    """
    # Load agent configuration
    config = get_daily_agent_config(vault_path, agent_name)
    if not config:
        return {
            "status": "error",
            "error": f"Agent '{agent_name}' not found in Daily/.agents/",
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

    # Check if journal exists for this date (most agents need this)
    journal_file = vault_path / "Daily" / "journals" / f"{date}.md"
    if not journal_file.exists() and "read_journal" in config.tools:
        return {
            "status": "skipped",
            "reason": f"No journal found for {date}",
        }

    # Load user context
    user_name, user_context = load_user_context(vault_path)

    # Format system prompt with user context
    system_prompt = config.system_prompt
    if "{user_name}" in system_prompt or "{user_context}" in system_prompt:
        system_prompt = system_prompt.format(user_name=user_name, user_context=user_context)
    elif user_context:
        system_prompt = system_prompt + f"\n\n## User Context\n\n{user_context}"

    # Import SDK and create tools
    from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query
    from parachute.core.daily_agent_tools import create_daily_agent_tools

    # Create tools for this agent
    if create_tools_fn:
        _tools, agent_mcp_config = await create_tools_fn(vault_path, config)
    else:
        _tools, agent_mcp_config = create_daily_agent_tools(vault_path, config)

    # Load vault MCPs
    vault_mcps = await load_vault_mcps(vault_path)

    # Combine all MCP servers
    all_mcp_servers = {
        f"daily_{agent_name}": agent_mcp_config,
        **vault_mcps,
    }

    logger.info(f"Running agent '{agent_name}' with MCPs: {list(all_mcp_servers.keys())}")

    # Build the prompt
    if build_prompt_fn:
        prompt_text = build_prompt_fn(config, date, output_date)
    else:
        prompt_text = _default_prompt(config, date, output_date)

    # Wrap prompt in async generator with delay
    # The delay ensures the SDK transport and MCP servers are ready
    # before the first message is sent (workaround for SDK timing issue)
    async def generate_prompt():
        import asyncio
        await asyncio.sleep(1.0)  # Wait for transport/MCP initialization
        yield {"type": "user", "message": {"role": "user", "content": prompt_text}}

    # Build options
    options_kwargs = {
        "system_prompt": system_prompt,
        "max_turns": 20,
        "mcp_servers": all_mcp_servers,
        "permission_mode": "bypassPermissions",
        "stderr": lambda msg: logger.error(f"CLI STDERR: {msg}"),
        "debug_stderr": sys.stderr,  # Also write to actual stderr for debugging
    }

    # Resume existing session if available
    if state.sdk_session_id:
        options_kwargs["resume"] = state.sdk_session_id

    options = ClaudeAgentOptions(**options_kwargs)

    result = {
        "status": "running",
        "agent": agent_name,
        "date": date,
        "output_date": output_date,
        "sdk_session_id": state.sdk_session_id,
        "mcp_servers": list(all_mcp_servers.keys()),
    }

    # Helper to run the query with retry logic for stale sessions
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

                        # Track if output was written
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
            # Check for stale session errors - retry without resume
            if retry_on_stale and ("no conversation found" in error_str or "session" in error_str and "not found" in error_str):
                logger.warning(
                    f"Agent '{agent_name}' session expired (id={opts.resume}), "
                    "clearing and retrying with fresh session"
                )
                # Clear the stale session from state
                state.sdk_session_id = None
                state.save()

                # Create new options without resume
                fresh_opts_kwargs = {
                    "system_prompt": opts.system_prompt,
                    "max_turns": opts.max_turns,
                    "mcp_servers": opts.mcp_servers,
                    "permission_mode": opts.permission_mode,
                }
                fresh_opts = ClaudeAgentOptions(**fresh_opts_kwargs)

                # Retry without resume (don't retry again on failure)
                return await run_query_with_retry(fresh_opts, retry_on_stale=False)

            # Re-raise other errors
            raise

    try:
        query_result = await run_query_with_retry(options)

        new_session_id = query_result["new_session_id"]
        model_used = query_result["model_used"]
        output_written = query_result["output_written"]

        # Update state
        state.record_run(date, new_session_id, model_used)

        output_path = config.get_output_path(output_date)
        result["status"] = "completed" if output_written else "completed_no_output"
        result["sdk_session_id"] = new_session_id
        result["model"] = model_used
        result["output_written"] = output_written
        result["output_path"] = output_path if output_written else None
        result["journal_date"] = date
        result["output_date"] = output_date

        logger.info(f"Agent '{agent_name}' completed for {date}: output_written={output_written}")

    except Exception as e:
        logger.error(f"Agent '{agent_name}' error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)

    return result


def _default_prompt(config: DailyAgentConfig, journal_date: str, output_date: str) -> str:
    """Build a default prompt for an agent."""
    return f"""Today is {output_date}. Please run your daily process based on yesterday ({journal_date}).

Use the tools available to you:
- `read_journal` with date "{journal_date}" to read yesterday's journal entries
- `read_chat_log` with date "{journal_date}" to read AI conversations from yesterday
- `read_recent_journals` for broader context from recent days

When you're ready, use `write_output` with date "{output_date}" to save your output.
"""
