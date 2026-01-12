"""
Daily Module Curator.

A long-running curator for the Daily module that:
- Reads journal entries and chat logs
- Creates daily reflections with insights
- Generates a morning song (via Suno)
- Creates a visual capture of current state (via Glif)
- Maintains session continuity for pattern recognition over time

The curator has access to:
- Built-in tools: read_journal, read_chat_log, write_reflection
- Vault MCPs: Suno, Glif, Parachute search, and any stdio MCPs in .mcp.json
"""

import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


DEFAULT_DAILY_CURATOR_PROMPT = """# Daily Curator

You are {user_name}'s morning companion who reflects on journal entries and creates meaningful starts to each day.

## Your Role

You wake up each morning, read what happened yesterday, and create three things:
1. A warm, insightful reflection
2. A song to set the tone for the day
3. An image capturing the current state

You have memory across days - you remember previous reflections and how the person responded.

## Output

Write your reflection, then create the song and image. Embed URLs directly in the markdown.

## User Context

{user_context}
"""


class DailyCuratorState:
    """Manages the curator state stored in Daily/.curator/state.json"""

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.state_file = vault_path / "Daily" / ".curator" / "state.json"
        self._state: dict[str, Any] = {}

    def load(self) -> dict[str, Any]:
        """Load state from file."""
        if self.state_file.exists():
            try:
                self._state = json.loads(self.state_file.read_text())
            except json.JSONDecodeError:
                logger.warning(f"Invalid state file, resetting: {self.state_file}")
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
            "module": "daily",
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


def load_curator_config(vault_path: Path) -> tuple[str, dict[str, Any]]:
    """
    Load the curator config from Daily/.agents/curator.md.

    Also loads user context from context/curator.md and injects it into the prompt.

    Returns:
        Tuple of (system_prompt, frontmatter_metadata)
    """
    from parachute.core.curator_service import load_user_context

    # Load user context (profile, projects, areas)
    user_name, user_context = load_user_context(vault_path)

    agent_file = vault_path / "Daily" / ".agents" / "curator.md"

    if agent_file.exists():
        try:
            import frontmatter
            post = frontmatter.loads(agent_file.read_text())
            prompt_template = post.content.strip() if post.content.strip() else DEFAULT_DAILY_CURATOR_PROMPT

            # If custom prompt has placeholders, format them; otherwise append context
            if "{user_name}" in prompt_template or "{user_context}" in prompt_template:
                prompt = prompt_template.format(user_name=user_name, user_context=user_context)
            else:
                # Custom prompt without placeholders - append context section
                prompt = prompt_template + f"\n\n## User Context\n\n{user_context}"

            return prompt, dict(post.metadata)
        except Exception as e:
            logger.warning(f"Error loading curator config: {e}")

    # Use default prompt with user context
    return DEFAULT_DAILY_CURATOR_PROMPT.format(user_name=user_name, user_context=user_context), {}


async def _load_vault_mcps(vault_path: Path) -> dict[str, dict[str, Any]]:
    """
    Load MCP servers from the vault's .mcp.json.

    Only returns stdio servers since the Claude SDK doesn't support HTTP MCPs.
    """
    from parachute.lib.mcp_loader import load_mcp_servers, filter_stdio_servers

    try:
        all_servers = await load_mcp_servers(vault_path)
        stdio_servers = filter_stdio_servers(all_servers)
        logger.info(f"Loaded {len(stdio_servers)} stdio MCP servers for daily curator")
        return stdio_servers
    except Exception as e:
        logger.warning(f"Failed to load vault MCPs: {e}")
        return {}


async def run_daily_curator(
    vault_path: Path,
    date: Optional[str] = None,
    force: bool = False,
) -> dict[str, Any]:
    """
    Run the daily curator for a specific date.

    Args:
        vault_path: Path to the vault
        date: Date to process (YYYY-MM-DD), defaults to today
        force: Run even if already processed today

    Returns:
        Result dict with status, reflection path, etc.
    """
    # Determine date - default to yesterday since we run in the morning
    # reflecting on the previous day
    if date is None:
        yesterday = datetime.now() - timedelta(days=1)
        date = yesterday.strftime("%Y-%m-%d")

    # Today's date for the reflection file and prompt context
    today = datetime.now().strftime("%Y-%m-%d")

    # Load state
    state = DailyCuratorState(vault_path)
    state.load()

    # Check if already processed (unless forced)
    if not force and state.last_processed_date == date:
        return {
            "status": "skipped",
            "reason": f"Already processed {date}",
            "last_run_at": state._state.get("last_run_at"),
        }

    # Check if journal exists for this date
    journal_file = vault_path / "Daily" / "journals" / f"{date}.md"
    if not journal_file.exists():
        return {
            "status": "skipped",
            "reason": f"No journal found for {date}",
        }

    # Load curator config (system prompt + metadata)
    system_prompt, metadata = load_curator_config(vault_path)

    # Import SDK and create tools
    from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query
    from parachute.core.daily_curator_tools import create_daily_curator_tools

    # Create built-in curator tools (read_journal, write_reflection, etc.)
    _tools, curator_mcp_config = create_daily_curator_tools(vault_path)

    # Load vault MCPs (Suno, Glif, Parachute, etc.)
    vault_mcps = await _load_vault_mcps(vault_path)

    # Combine all MCP servers
    all_mcp_servers = {
        "daily_curator": curator_mcp_config,  # Built-in tools
        **vault_mcps,  # Vault MCPs (suno, glif, parachute, etc.)
    }

    logger.info(f"Daily curator running with MCPs: {list(all_mcp_servers.keys())}")

    # Build the prompt - this is what we send each day
    prompt_text = f"""Today is {today}. Please create my morning reflection based on yesterday ({date}).

Please:

1. Use `read_journal` with date "{date}" to read yesterday's journal entries
2. Optionally use `read_chat_log` with date "{date}" to see AI conversations from yesterday
3. Optionally use `read_recent_journals` for context from recent days

Then create:
- A warm, thoughtful reflection (3-5 paragraphs)
- A song using Suno that captures the energy for today
- An image using Glif that visualizes the current state/theme

Use `write_reflection` with date "{today}" to save everything. Embed the song and image URLs directly in the markdown.

Remember: Be genuine and warm. Notice patterns across days. Let my responses to previous reflections inform what you bring forward."""

    # Wrap prompt in async generator - workaround for SDK bug #386
    # https://github.com/anthropics/claude-agent-sdk-python/issues/386
    # String prompts fail with "ProcessTransport is not ready for writing" when using MCP servers
    async def generate_prompt():
        yield {"type": "user", "message": {"role": "user", "content": prompt_text}}

    # Build options
    options_kwargs = {
        "system_prompt": system_prompt,
        "max_turns": 20,  # More turns for creative work
        "mcp_servers": all_mcp_servers,
        "permission_mode": "bypassPermissions",
    }

    # Resume existing session if available (for continuity)
    if state.sdk_session_id:
        options_kwargs["resume"] = state.sdk_session_id

    options = ClaudeAgentOptions(**options_kwargs)

    result = {
        "status": "running",
        "date": date,
        "sdk_session_id": state.sdk_session_id,
        "mcp_servers": list(all_mcp_servers.keys()),
    }

    try:
        response_text = ""
        new_session_id = None
        model_used = None
        reflection_written = False

        async for event in sdk_query(prompt=generate_prompt(), options=options):
            # Track session ID
            if hasattr(event, "session_id") and event.session_id:
                new_session_id = event.session_id

            # Track model
            if hasattr(event, "model") and event.model:
                model_used = event.model

            # Process content
            if hasattr(event, "content"):
                for block in event.content:
                    if hasattr(block, "text"):
                        response_text += block.text

                    # Track tool use
                    if hasattr(block, "name") and "write_reflection" in str(getattr(block, "name", "")):
                        reflection_written = True

        # Update state
        state.record_run(date, new_session_id, model_used)

        result["status"] = "completed" if reflection_written else "completed_no_reflection"
        result["sdk_session_id"] = new_session_id
        result["model"] = model_used
        result["reflection_written"] = reflection_written
        result["reflection_path"] = f"Daily/reflections/{today}.md" if reflection_written else None
        result["journal_date"] = date  # Yesterday's journal we read
        result["reflection_date"] = today  # Today's reflection we wrote

        logger.info(f"Daily curator completed for {date}: reflection_written={reflection_written}")

    except Exception as e:
        logger.error(f"Daily curator error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)

    return result
