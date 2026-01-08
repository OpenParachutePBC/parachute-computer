"""
Daily Module Curator.

A long-running curator for the Daily module that:
- Reads journal entries
- Creates daily reflections
- Maintains session continuity for pattern recognition over time

Unlike the chat curator (which runs per-session), the module curator
runs once per day and has memory across all days.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


# System prompt loaded from Daily/.agents/curator.md if it exists
DEFAULT_DAILY_CURATOR_PROMPT = """# Daily Curator

You are a reflective companion who reads journal entries and writes thoughtful reflections.

## Your Role

You're like a thoughtful friend who listened to everything they shared today and mirrors it back with care. You're not here to give advice or be prescriptive - you're here to help them feel heard and see their own thoughts from a fresh angle.

## What You Do

1. Read today's journal entries
2. Notice themes and patterns
3. Reflect back warmly
4. Ask gentle questions if natural
5. Surface connections to their interests

## Your Tone

- Warm and conversational
- Non-judgmental
- Curious but not intrusive
- Brief (3-5 paragraphs)
- Genuine, not performatively positive

## Output

Write a reflection starting with "## Reflection - {date}" and keep it to 3-5 paragraphs.
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


def load_curator_prompt(vault_path: Path) -> str:
    """Load the curator prompt from Daily/.agents/curator.md or use default."""
    agent_file = vault_path / "Daily" / ".agents" / "curator.md"

    if agent_file.exists():
        try:
            import frontmatter
            post = frontmatter.loads(agent_file.read_text())
            if post.content.strip():
                return post.content.strip()
        except Exception as e:
            logger.warning(f"Error loading curator prompt: {e}")

    return DEFAULT_DAILY_CURATOR_PROMPT


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
    # Determine date
    if date is None:
        date = datetime.now().strftime("%Y-%m-%d")

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

    # Load system prompt
    system_prompt = load_curator_prompt(vault_path)

    # Import SDK here to avoid import errors when not needed
    from claude_code_sdk import ClaudeCodeOptions, query as sdk_query

    # Create tools via MCP server
    import sys
    base_dir = Path(__file__).parent.parent
    venv_python = base_dir / "venv" / "bin" / "python"
    python_path = str(venv_python) if venv_python.exists() else sys.executable

    daily_mcp_config = {
        "command": python_path,
        "args": ["-m", "parachute.daily_curator_mcp_server"],
        "env": {
            "PARACHUTE_VAULT_PATH": str(vault_path),
            "PYTHONPATH": str(base_dir),
        },
    }

    # Build the prompt
    prompt = f"""Today's date is {date}. Please:

1. Use `read_journal` to read today's journal entries
2. Optionally use `read_recent_journals` if you want context from recent days
3. Write a warm, thoughtful reflection
4. Use `write_reflection` to save it

Remember: Be genuine, brief (3-5 paragraphs), and mirror back what you noticed without being preachy."""

    # Build options
    options_kwargs = {
        "system_prompt": system_prompt,
        "max_turns": 10,  # Allow multiple tool calls
        "mcp_servers": {"daily_curator": daily_mcp_config},
        "permission_mode": "bypassPermissions",
    }

    # Resume existing session if available
    if state.sdk_session_id:
        options_kwargs["resume"] = state.sdk_session_id

    options = ClaudeCodeOptions(**options_kwargs)

    result = {
        "status": "running",
        "date": date,
        "sdk_session_id": state.sdk_session_id,
    }

    try:
        response_text = ""
        new_session_id = None
        model_used = None
        reflection_written = False

        async for event in sdk_query(prompt=prompt, options=options):
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
                    if hasattr(block, "name") and "write_reflection" in block.name:
                        reflection_written = True

        # Update state
        state.record_run(date, new_session_id, model_used)

        result["status"] = "completed" if reflection_written else "completed_no_reflection"
        result["sdk_session_id"] = new_session_id
        result["model"] = model_used
        result["reflection_written"] = reflection_written
        result["reflection_path"] = f"Daily/reflections/{date}.md" if reflection_written else None

        logger.info(f"Daily curator completed for {date}: reflection_written={reflection_written}")

    except Exception as e:
        logger.error(f"Daily curator error: {e}", exc_info=True)
        result["status"] = "error"
        result["error"] = str(e)

    return result
