"""
Event-driven Tool dispatcher.

Discovers triggered Tools matching a Note lifecycle event (e.g.,
"note.transcription_complete") via Trigger→Tool graph edges and
invokes them sequentially on the triggering entry.

The dispatcher is event-agnostic — it finds, invokes, and records.
Lifecycle bookkeeping (cleanup_status, transcription_status) belongs
in the module that owns the domain semantics (DailyModule).
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


class AgentDispatcher:
    """Discovers triggered Tools and invokes them when events fire."""

    def __init__(self, graph: Any, home_path: Path):
        self.graph = graph
        self.home_path = home_path

    async def dispatch(
        self,
        event: str,
        entry_id: str,
        entry_meta: dict[str, Any],
    ) -> list[dict[str, Any]]:
        """
        Find Tools matching this event + filter, invoke them sequentially.

        Sequential execution ensures earlier Tools' mutations (e.g., cleanup)
        are visible to later Tools (e.g., tagging) on the same Note.

        Args:
            event: The lifecycle event (e.g., "note.transcription_complete")
            entry_id: The Note entry_id
            entry_meta: Note metadata for filter matching (entry_type, tags, date)

        Returns:
            List of result dicts from each invoked Tool
        """
        if self.graph is None:
            logger.warning("AgentDispatcher: graph unavailable, skipping dispatch")
            return []

        # Discover matching Agents
        agents = await self._find_matching_agents(event, entry_meta)
        if not agents:
            logger.debug(f"AgentDispatcher: no agents match event={event} for entry {entry_id}")
            return []

        logger.info(
            f"AgentDispatcher: {len(agents)} agent(s) match event={event} "
            f"for entry {entry_id}: {[a['name'] for a in agents]}"
        )

        results = []
        for agent_row in agents:
            agent_name = agent_row["name"]
            display_name = agent_row.get("display_name") or agent_name.replace("-", " ").title()
            result = await self._invoke_agent(
                agent_name, entry_id, event, entry_meta,
                display_name=display_name,
            )
            results.append(result)

        return results

    async def _find_matching_agents(
        self,
        event: str,
        entry_meta: dict[str, Any],
    ) -> list[dict[str, Any]]:
        """Query Trigger→Tool graph for tools matching this event."""
        matching = []
        try:
            rows = await self.graph.execute_cypher(
                "MATCH (tr:Trigger)-[:INVOKES]->(t:Tool) "
                "WHERE tr.enabled = 'true' AND tr.event = $event "
                "RETURN t.name AS name, t.display_name AS display_name, "
                "       tr.event_filter AS event_filter "
                "ORDER BY t.name",
                {"event": event},
            )
            for row in rows:
                filter_raw = row.get("event_filter") or "{}"
                try:
                    trigger_filter = json.loads(filter_raw) if isinstance(filter_raw, str) else filter_raw
                except (json.JSONDecodeError, TypeError):
                    trigger_filter = {}

                if self._matches_filter(trigger_filter, entry_meta):
                    matching.append(row)
                else:
                    logger.debug(
                        f"AgentDispatcher: tool '{row.get('name')}' "
                        f"filter {trigger_filter} doesn't match entry meta"
                    )
        except Exception as e:
            logger.error(f"AgentDispatcher: Trigger→Tool query failed: {e}")

        return matching

    @staticmethod
    def _matches_filter(
        trigger_filter: dict[str, Any],
        entry_meta: dict[str, Any],
    ) -> bool:
        """
        Check if an entry's metadata matches an Agent's trigger_filter.

        Filter semantics:
        - {} → always matches (no filter)
        - {"entry_type": "voice"} → entry must have matching entry_type
        - {"tags": ["meeting"]} → entry must have at least one matching tag
        - Multiple keys → ALL must match (AND)
        """
        if not trigger_filter:
            return True

        for key, expected in trigger_filter.items():
            actual = entry_meta.get(key)

            if key == "tags":
                # Tags filter: entry must have at least one of the expected tags
                entry_tags = actual or []
                if isinstance(entry_tags, str):
                    entry_tags = [entry_tags]
                expected_tags = expected if isinstance(expected, list) else [expected]
                if not any(t in entry_tags for t in expected_tags):
                    return False

            elif key == "entry_type":
                # Simple equality check
                if actual != expected:
                    return False

            else:
                # Generic equality for any other filter key
                if actual != expected:
                    return False

        return True

    async def _invoke_agent(
        self,
        agent_name: str,
        entry_id: str,
        event: str,
        entry_meta: dict[str, Any],
        display_name: str = "",
    ) -> dict[str, Any]:
        """Invoke a single triggered Agent. Event-agnostic — just invoke + record."""
        from parachute.core.daily_agent import run_triggered_agent

        ran_at = datetime.now(timezone.utc).isoformat()

        try:
            result = await run_triggered_agent(
                home_path=self.home_path,
                agent_name=agent_name,
                entry_id=entry_id,
                event=event,
            )

            status = result.get("status", "error")
            session_id = result.get("sdk_session_id")

            await self._record_activity(
                agent_name=agent_name,
                display_name=display_name,
                entry_id=entry_id,
                status=status,
                ran_at=ran_at,
                session_id=session_id or "",
            )

            logger.info(
                f"AgentDispatcher: agent '{agent_name}' on entry {entry_id} "
                f"→ {status}"
            )
            return result

        except Exception as e:
            logger.error(
                f"AgentDispatcher: agent '{agent_name}' failed on entry {entry_id}: {e}",
                exc_info=True,
            )

            await self._record_activity(
                agent_name=agent_name,
                display_name=display_name,
                entry_id=entry_id,
                status="error",
                ran_at=ran_at,
                session_id="",
            )

            return {
                "status": "error",
                "agent": agent_name,
                "entry_id": entry_id,
                "error": str(e),
            }

    async def _record_activity(
        self,
        agent_name: str,
        display_name: str,
        entry_id: str,
        status: str,
        ran_at: str,
        session_id: str,
    ) -> None:
        """Record that a Tool ran on a Note (for UI display)."""
        run_id = f"{agent_name}:{entry_id}:{ran_at}"
        try:
            async with self.graph.write_lock:
                await self.graph.execute_cypher(
                    "MERGE (r:ToolRun {run_id: $run_id}) "
                    "SET r.tool_name = $tool_name, "
                    "    r.display_name = $display_name, "
                    "    r.entry_id = $entry_id, "
                    "    r.status = $status, "
                    "    r.started_at = $ran_at, "
                    "    r.completed_at = $ran_at, "
                    "    r.session_id = $session_id, "
                    "    r.trigger_name = 'event', "
                    "    r.created_at = $ran_at",
                    {
                        "run_id": run_id,
                        "tool_name": agent_name,
                        "display_name": display_name,
                        "entry_id": entry_id,
                        "status": status,
                        "ran_at": ran_at,
                        "session_id": session_id,
                    },
                )
        except Exception as e:
            logger.warning(f"AgentDispatcher: failed to record activity: {e}")
