"""
Day-scoped agent tools.

Tools that operate on a date's worth of data — notes, chat logs, etc.
Each factory creates a single SDK tool bound to scope data via closure.

Also provides create_daily_agent_tools() for backwards compatibility with
the old monolithic tool creation pattern.
"""

import logging
import re
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, TYPE_CHECKING

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

if TYPE_CHECKING:
    from parachute.core.daily_agent import DailyAgentConfig

logger = logging.getLogger(__name__)


# ── Individual tool factories ─────────────────────────────────────────────────
# Each returns a single SdkMcpTool, bound to scope data via closure.
# Signature: (graph, scope, agent_name, home_path) -> SdkMcpTool


def _make_read_days_notes(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Read all notes for a specific date from the graph."""

    @tool(
        "read_days_notes",
        "Read all notes for a specific date. Returns the full content of that day's entries.",
        {"date": str},
    )
    async def read_days_notes(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}], "is_error": True}

        if graph is None:
            return {"content": [{"type": "text", "text": f"No notes found for {date_str} (graph unavailable)"}]}

        try:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date "
                "RETURN e.content AS content, e.created_at AS created_at "
                "ORDER BY e.created_at ASC",
                {"date": date_str},
            )
            if not rows:
                return {"content": [{"type": "text", "text": f"No notes found for {date_str}"}]}
            entries_text = "\n\n---\n\n".join(r["content"] for r in rows if r.get("content"))
            return {"content": [{"type": "text", "text": f"# Notes for {date_str}\n\n{entries_text}"}]}
        except Exception as e:
            logger.error(f"Error reading notes from graph: {e}")
            return {"content": [{"type": "text", "text": f"Error reading notes: {e}"}], "is_error": True}

    return read_days_notes


def _make_read_days_chats(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Read AI chat sessions active on a specific date from the graph."""

    @tool(
        "read_days_chats",
        "List chat sessions active on a specific date. Returns session IDs, titles, message counts, and time ranges — no raw messages. Use summarize_chat to get details on individual sessions.",
        {"date": str},
    )
    async def read_days_chats(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}], "is_error": True}

        if graph is None:
            return {"content": [{"type": "text", "text": f"No chat sessions found for {date_str} (graph unavailable)"}]}

        try:
            # Parse date to create start/end range
            date_obj = datetime.strptime(date_str, "%Y-%m-%d").date()
            date_start = f"{date_obj.isoformat()}T00:00:00"
            date_end = f"{(date_obj + timedelta(days=1)).isoformat()}T00:00:00"

            rows = await graph.execute_cypher(
                "MATCH (s:Chat)-[:HAS_MESSAGE]->(m:Message) "
                "WHERE m.created_at >= $date_start AND m.created_at < $date_end "
                "  AND s.module = 'chat' "
                "WITH s, count(m) AS msg_count, "
                "     min(m.created_at) AS first_msg, max(m.created_at) AS last_msg "
                "RETURN s.session_id AS session_id, s.title AS title, "
                "       s.summary AS summary, msg_count, first_msg, last_msg "
                "ORDER BY first_msg ASC",
                {"date_start": date_start, "date_end": date_end},
            )

            if not rows:
                return {"content": [{"type": "text", "text": f"No chat sessions found for {date_str}"}]}

            lines = [f"# Chat Sessions for {date_str}\n"]
            for r in rows:
                title = r.get("title") or "(untitled)"
                sid = r.get("session_id", "?")
                count = r.get("msg_count", 0)
                first = r.get("first_msg", "")
                last = r.get("last_msg", "")
                summary = r.get("summary") or ""

                lines.append(f"## {title}")
                lines.append(f"- **Session ID:** {sid}")
                lines.append(f"- **Messages today:** {count}")
                if first and last:
                    lines.append(f"- **Time range:** {first} → {last}")
                if summary:
                    lines.append(f"- **Summary:** {summary}")
                lines.append("")

            return {"content": [{"type": "text", "text": "\n".join(lines)}]}
        except Exception as e:
            logger.error(f"Error reading chat sessions from graph: {e}")
            return {"content": [{"type": "text", "text": f"Error reading chat sessions: {e}"}], "is_error": True}

    return read_days_chats


SUMMARIZER_SYSTEM_PROMPT = (
    "You are a conversation summarizer. Given a full chat transcript, produce "
    "two clearly separated sections:\n\n"
    "1. SESSION SUMMARY: A 2-3 sentence overview of what this conversation is about "
    "overall — its purpose, key topics, and current state.\n\n"
    "2. TODAY'S ACTIVITY ({date}): A focused summary of what specifically happened "
    "on this date. What was discussed, decided, built, or resolved? Be specific "
    "about outcomes and artifacts (PRs, files, decisions).\n\n"
    "Messages from today are marked with [TODAY]. Earlier messages provide context.\n\n"
    "Format your response exactly as:\n"
    "SESSION SUMMARY:\n<your summary>\n\n"
    "TODAY'S ACTIVITY:\n<your summary>"
)


def _make_summarize_chat(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Summarize a chat session's activity for a specific date using a Haiku sub-agent."""

    @tool(
        "summarize_chat",
        "Summarize a chat session's activity for a specific date. Spawns a fast sub-agent to read the full transcript and return a focused summary of what happened today. Also persists a full session summary.",
        {"session_id": str},
    )
    async def summarize_chat(args: dict[str, Any]) -> dict[str, Any]:
        session_id = args.get("session_id", "").strip()
        if not session_id:
            return {"content": [{"type": "text", "text": "Error: session_id is required"}], "is_error": True}

        date_str = scope.get("date", "")
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date not available in scope"}], "is_error": True}

        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable"}], "is_error": True}

        try:
            # Check if summary is fresh (no new messages since last summarization)
            cache_rows = await graph.execute_cypher(
                "MATCH (s:Chat {session_id: $sid}) "
                "RETURN s.summary AS summary, s.summary_updated_at AS summary_updated_at, "
                "       s.last_accessed AS last_accessed",
                {"sid": session_id},
            )
            if cache_rows:
                cached = cache_rows[0]
                summary_updated = cached.get("summary_updated_at") or ""
                last_accessed = cached.get("last_accessed") or ""
                existing_summary = cached.get("summary") or ""
                # If summary exists and was updated after last access, skip re-summarization
                if existing_summary and summary_updated and last_accessed and summary_updated >= last_accessed:
                    logger.info(f"Summary for {session_id} is fresh, skipping re-summarization")
                    return {"content": [{"type": "text", "text": f"(cached) {existing_summary}"}]}

            # Parse date for filtering
            date_obj = datetime.strptime(date_str, "%Y-%m-%d").date()
            date_start = f"{date_obj.isoformat()}T00:00:00"
            date_end = f"{(date_obj + timedelta(days=1)).isoformat()}T00:00:00"

            # Check if session has messages on target date
            count_rows = await graph.execute_cypher(
                "MATCH (s:Chat {session_id: $sid})-[:HAS_MESSAGE]->(m:Message) "
                "WHERE m.created_at >= $date_start AND m.created_at < $date_end "
                "RETURN count(m) AS today_count",
                {"sid": session_id, "date_start": date_start, "date_end": date_end},
            )
            today_count = count_rows[0]["today_count"] if count_rows else 0
            if today_count == 0:
                return {"content": [{"type": "text", "text": f"No messages on {date_str} for this session"}]}

            # Read all messages for the session, ordered by sequence
            msg_rows = await graph.execute_cypher(
                "MATCH (s:Chat {session_id: $sid})-[:HAS_MESSAGE]->(m:Message) "
                "RETURN m.role AS role, m.content AS content, m.created_at AS created_at, "
                "       m.sequence AS sequence "
                "ORDER BY m.sequence ASC",
                {"sid": session_id},
            )

            if not msg_rows:
                return {"content": [{"type": "text", "text": f"No messages found for session {session_id}"}]}

            # Build transcript with [TODAY] markers
            transcript_lines = []
            for msg in msg_rows:
                role = msg.get("role", "unknown")
                content = msg.get("content", "")
                created_at = msg.get("created_at", "")
                is_today = created_at >= date_start and created_at < date_end if created_at else False

                role_label = "User" if role == "human" else "Assistant"
                marker = " [TODAY]" if is_today else ""
                transcript_lines.append(f"**{role_label}**{marker}: {content}")

            transcript_text = "\n\n".join(transcript_lines)

            # Truncate older messages if very long, keep all of today's messages
            max_chars = 180_000  # Stay well within Haiku's 200K context
            if len(transcript_text) > max_chars:
                # Keep all [TODAY] messages, truncate older ones
                today_lines = [l for l in transcript_lines if "[TODAY]" in l]
                older_lines = [l for l in transcript_lines if "[TODAY]" not in l]
                today_text = "\n\n".join(today_lines)
                remaining = max_chars - len(today_text) - 200  # buffer for truncation notice
                if remaining > 0:
                    older_text = "\n\n".join(older_lines)
                    if len(older_text) > remaining:
                        older_text = older_text[:remaining] + "\n\n...(earlier messages truncated)"
                    transcript_text = older_text + "\n\n---\n\n" + today_text
                else:
                    transcript_text = today_text

            # Call Haiku sub-agent
            system_prompt = SUMMARIZER_SYSTEM_PROMPT.replace("{date}", date_str)
            response = await _call_summarizer_subagent(system_prompt, transcript_text)

            # Parse response into session summary + today's activity
            session_summary, todays_activity = _parse_summarizer_response(response)

            # Persist session summary to graph
            now_iso = datetime.now(timezone.utc).isoformat()
            await graph.execute_cypher(
                "MATCH (s:Chat {session_id: $sid}) "
                "SET s.summary = $summary, s.summary_updated_at = $updated_at",
                {"sid": session_id, "summary": session_summary, "updated_at": now_iso},
            )

            return {"content": [{"type": "text", "text": todays_activity or session_summary}]}

        except Exception as e:
            logger.error(f"Error summarizing chat {session_id}: {e}")
            return {"content": [{"type": "text", "text": f"Error summarizing chat: {e}"}], "is_error": True}

    return summarize_chat


async def _call_summarizer_subagent(system_prompt: str, transcript_text: str) -> str:
    """Call a Haiku sub-agent to summarize a chat transcript."""
    import asyncio
    import os

    from claude_agent_sdk import ClaudeAgentOptions, query as sdk_query

    done_event = asyncio.Event()

    async def prompt_gen():
        yield {"type": "user", "message": {"role": "user", "content": transcript_text}}
        await done_event.wait()

    # Build env — clear CLAUDECODE to avoid nested session detection
    sdk_env: dict[str, str] = dict(os.environ)
    sdk_env["CLAUDECODE"] = ""

    opts = ClaudeAgentOptions(
        system_prompt=system_prompt,
        max_turns=1,
        permission_mode="bypassPermissions",
        model="haiku",
        env=sdk_env,
    )

    response = ""
    try:
        async for event in sdk_query(prompt=prompt_gen(), options=opts):
            if hasattr(event, "content"):
                for block in event.content:
                    if hasattr(block, "text"):
                        response += block.text
            if getattr(event, "type", None) == "result":
                done_event.set()
    except Exception as e:
        done_event.set()
        raise e
    finally:
        done_event.set()

    return response


def _parse_summarizer_response(response: str) -> tuple[str, str]:
    """Parse the summarizer's response into (session_summary, todays_activity)."""
    session_summary = ""
    todays_activity = ""

    # Try to parse structured response
    if "SESSION SUMMARY:" in response and "TODAY'S ACTIVITY:" in response:
        parts = response.split("TODAY'S ACTIVITY:")
        session_part = parts[0]
        todays_activity = parts[1].strip() if len(parts) > 1 else ""

        # Extract session summary (after "SESSION SUMMARY:" header)
        if "SESSION SUMMARY:" in session_part:
            session_summary = session_part.split("SESSION SUMMARY:")[1].strip()
        else:
            session_summary = session_part.strip()
    else:
        # Fallback: treat entire response as both summary and activity
        session_summary = response.strip()
        todays_activity = response.strip()

    return session_summary, todays_activity


def _make_read_recent_journals(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Read journal entries from the past N days for context."""

    @tool(
        "read_recent_journals",
        "Read journal entries from the past N days for context. Useful for noticing patterns across days.",
        {"days": int},
    )
    async def read_recent_journals(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)

        if graph is None:
            return {"content": [{"type": "text", "text": "Graph unavailable — cannot read recent journals"}]}

        today = datetime.now().astimezone().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            try:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note) WHERE e.date = $date "
                    "RETURN e.content AS content ORDER BY e.created_at ASC",
                    {"date": date_str},
                )
                if rows:
                    content = "\n\n".join(r["content"] for r in rows if r.get("content"))
                    if len(content) > 5000:
                        content = content[:5000] + "\n\n...(truncated)"
                    journals_found.append(f"## {date_str}\n\n{content}")
            except Exception:
                continue

        if not journals_found:
            return {"content": [{"type": "text", "text": f"No journals found in the past {days_back} days"}]}

        return {"content": [{"type": "text", "text": f"# Recent Journals ({len(journals_found)} days)\n\n" + "\n\n---\n\n".join(journals_found)}]}

    return read_recent_journals


def _make_read_recent_sessions(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Read recent AI chat sessions for context from vault files."""
    chat_log_dir = home_path / "Daily" / "chat-log"

    @tool(
        "read_recent_sessions",
        "Read recent AI chat sessions for context. Returns summaries of recent conversations.",
        {"days": int},
    )
    async def read_recent_sessions(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)

        today = datetime.now().astimezone().date()
        logs_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            log_file = chat_log_dir / f"{date_str}.md"
            if log_file.exists():
                try:
                    content = log_file.read_text(encoding="utf-8")
                    if len(content) > 3000:
                        content = content[:3000] + "\n\n...(truncated)"
                    logs_found.append(f"## {date_str}\n\n{content}")
                except Exception:
                    continue

        if not logs_found:
            return {"content": [{"type": "text", "text": f"No chat logs found in the past {days_back} days"}]}

        return {"content": [{"type": "text", "text": f"# Recent Chat Sessions ({len(logs_found)} days)\n\n" + "\n\n---\n\n".join(logs_found)}]}

    return read_recent_sessions


def _make_read_recent_cards(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Read cards from recent days, optionally filtered by card_type."""

    @tool(
        "read_recent_cards",
        "Read cards from recent days. Filter by card_type (e.g. 'reflection') to see past outputs. Useful for week-over-week continuity.",
        {"days": int, "card_type": str},
    )
    async def read_recent_cards(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)
        card_type = args.get("card_type", "").strip()

        if graph is None:
            return {"content": [{"type": "text", "text": "Graph unavailable — cannot read cards"}]}

        today = datetime.now().astimezone().date()
        start_date = (today - timedelta(days=days_back)).isoformat()

        try:
            if card_type:
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) WHERE c.date >= $start_date "
                    "AND c.card_type = $card_type "
                    "RETURN c.card_id AS card_id, c.date AS date, c.card_type AS card_type, "
                    "       c.display_name AS display_name, c.content AS content, "
                    "       c.generated_at AS generated_at "
                    "ORDER BY c.date DESC",
                    {"start_date": start_date, "card_type": card_type},
                )
            else:
                rows = await graph.execute_cypher(
                    "MATCH (c:Card) WHERE c.date >= $start_date "
                    "RETURN c.card_id AS card_id, c.date AS date, c.card_type AS card_type, "
                    "       c.display_name AS display_name, c.content AS content, "
                    "       c.generated_at AS generated_at "
                    "ORDER BY c.date DESC",
                    {"start_date": start_date},
                )

            if not rows:
                type_note = f" of type '{card_type}'" if card_type else ""
                return {"content": [{"type": "text", "text": f"No cards{type_note} found in the past {days_back} days"}]}

            lines = [f"# Recent Cards ({len(rows)} found)\n"]
            for r in rows:
                date = r.get("date", "?")
                ctype = r.get("card_type", "?")
                display = r.get("display_name", "")
                content = r.get("content", "")
                lines.append(f"## {date} — {display} ({ctype})")
                lines.append(content)
                lines.append("")

            return {"content": [{"type": "text", "text": "\n".join(lines)}]}
        except Exception as e:
            logger.error(f"Error reading recent cards: {e}")
            return {"content": [{"type": "text", "text": f"Error reading cards: {e}"}], "is_error": True}

    return read_recent_cards


def _make_write_card(graph: Any, scope: dict, agent_name: str, home_path: Path) -> SdkMcpTool:
    """Write the agent's output as a Card to the graph."""

    @tool(
        "write_card",
        "Write the agent's output. Saves as a Card in the graph.",
        {"date": str, "content": str, "card_type": str},
    )
    async def write_card(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        content = args.get("content", "").strip()
        card_type = args.get("card_type", "default").strip() or "default"

        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required"}], "is_error": True}
        if not content:
            return {"content": [{"type": "text", "text": "Error: content is required"}], "is_error": True}
        if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,31}", card_type):
            return {"content": [{"type": "text", "text": "Error: invalid card_type — use lowercase alphanumeric with hyphens, max 32 chars"}], "is_error": True}
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable — cannot write output"}], "is_error": True}

        # Use display_name from scope if available (set by runner from config)
        display_name = scope.get("display_name", agent_name.replace("-", " ").title())
        card_id = f"{agent_name}:{card_type}:{date_str}"
        generated_at = datetime.now(timezone.utc).isoformat()

        try:
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.card_type = $card_type, "
                "    c.display_name = $display_name, "
                "    c.content = $content, "
                "    c.generated_at = $generated_at, "
                "    c.status = 'done', "
                "    c.date = $date, "
                "    c.read_at = ''",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
                    "card_type": card_type,
                    "display_name": display_name,
                    "content": content,
                    "generated_at": generated_at,
                    "date": date_str,
                },
            )
            logger.info(f"Agent '{agent_name}' wrote Card to graph for {date_str}")
            return {"content": [{"type": "text", "text": f"Successfully wrote output to graph (card_id: {card_id})"}]}
        except Exception as e:
            logger.error(f"Error writing Card to graph: {e}")
            return {"content": [{"type": "text", "text": f"Error writing output: {e}"}], "is_error": True}

    return write_card


# ── Register into shared registry ─────────────────────────────────────────────

from parachute.core.agent_tools import TOOL_FACTORIES  # noqa: E402

TOOL_FACTORIES["read_days_notes"] = (_make_read_days_notes, frozenset({"date"}))
TOOL_FACTORIES["read_days_chats"] = (_make_read_days_chats, frozenset({"date"}))
TOOL_FACTORIES["summarize_chat"] = (_make_summarize_chat, frozenset({"date"}))
TOOL_FACTORIES["read_recent_journals"] = (_make_read_recent_journals, frozenset())
TOOL_FACTORIES["read_recent_sessions"] = (_make_read_recent_sessions, frozenset())
TOOL_FACTORIES["read_recent_cards"] = (_make_read_recent_cards, frozenset())
TOOL_FACTORIES["write_card"] = (_make_write_card, frozenset())

# Legacy aliases — old tool names still work
TOOL_FACTORIES["read_journal"] = TOOL_FACTORIES["read_days_notes"]
TOOL_FACTORIES["read_chat_log"] = TOOL_FACTORIES["read_days_chats"]


# ── Backwards-compatible monolithic creator ───────────────────────────────────


def create_daily_agent_tools(
    home_path: Path,
    config: "DailyAgentConfig",
    graph=None,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for a daily agent (backwards-compatible).

    Delegates to bind_tools() with a day scope built from config.
    Kept for callers that haven't migrated to the unified runner yet.
    """
    from parachute.core.agent_tools import bind_tools

    scope = {
        "date": "",  # Placeholder — actual date comes from the prompt, not tool binding
        "display_name": config.display_name,
    }

    return bind_tools(
        tool_names=config.tools,
        scope=scope,
        graph=graph,
        agent_name=config.name,
        home_path=home_path,
    )
