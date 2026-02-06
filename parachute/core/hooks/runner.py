"""
Hook runner: discovers and executes lifecycle hooks.

Hooks are Python scripts in vault/.parachute/hooks/ that declare
which events they listen to via a module-level HOOK_CONFIG dict.

Example hook script:

    # vault/.parachute/hooks/session_summary.py
    HOOK_CONFIG = {
        "events": ["session.completed"],
        "blocking": False,
        "description": "Summarize session to activity log",
    }

    async def run(context: dict) -> None:
        session_id = context["session_id"]
        # ... generate summary ...
"""

import asyncio
import importlib.util
import logging
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from parachute.core.hooks.events import BLOCKING_EVENTS, HookEvent
from parachute.core.hooks.models import HookConfig, HookError

logger = logging.getLogger(__name__)

# Maximum recent errors to keep in memory
MAX_RECENT_ERRORS = 50


class HookRunner:
    """Discovers and executes hooks from vault/.parachute/hooks/."""

    def __init__(self, vault_path: Path):
        self.vault_path = vault_path
        self.hooks_dir = vault_path / ".parachute" / "hooks"
        self._hooks: dict[str, list[HookConfig]] = {}
        self._hook_modules: dict[str, Any] = {}  # name -> loaded module
        self._recent_errors: deque[HookError] = deque(maxlen=MAX_RECENT_ERRORS)

    async def discover(self) -> int:
        """Scan hooks directory for hook scripts. Returns count of hooks found."""
        self._hooks.clear()
        self._hook_modules.clear()

        if not self.hooks_dir.exists():
            logger.info("No hooks directory found")
            return 0

        count = 0
        for hook_file in sorted(self.hooks_dir.glob("*.py")):
            if hook_file.name.startswith("_"):
                continue  # Skip __init__.py, __pycache__, etc.

            try:
                config = self._parse_hook(hook_file)
                if not config or not config.enabled:
                    continue

                for event in config.events:
                    self._hooks.setdefault(event, []).append(config)

                count += 1
                logger.info(
                    f"Discovered hook: {config.name} "
                    f"(events: {', '.join(config.events)}, "
                    f"blocking: {config.blocking})"
                )
            except Exception as e:
                logger.error(f"Failed to parse hook {hook_file.name}: {e}")
                self._record_error(hook_file.name, "discover", str(e))

        logger.info(f"Discovered {count} hooks")
        return count

    def _parse_hook(self, hook_file: Path) -> HookConfig | None:
        """Parse a hook script and extract its configuration."""
        name = hook_file.stem

        try:
            spec = importlib.util.spec_from_file_location(
                f"parachute_hook_{name}", hook_file
            )
            if not spec or not spec.loader:
                return None

            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self._hook_modules[name] = module

            # Read HOOK_CONFIG from module
            hook_config = getattr(module, "HOOK_CONFIG", None)
            if not hook_config or not isinstance(hook_config, dict):
                logger.warning(f"Hook {name} has no HOOK_CONFIG dict, skipping")
                return None

            events = hook_config.get("events", [])
            if not events:
                logger.warning(f"Hook {name} has no events, skipping")
                return None

            # Determine if blocking (from config or from event type)
            blocking = hook_config.get("blocking", False)
            if not blocking:
                # Auto-detect blocking from event types
                for event_str in events:
                    try:
                        event = HookEvent(event_str)
                        if event in BLOCKING_EVENTS:
                            blocking = True
                            break
                    except ValueError:
                        pass  # Unknown event, not blocking

            return HookConfig(
                name=name,
                path=hook_file,
                events=events,
                blocking=blocking,
                timeout=hook_config.get("timeout", 30.0),
                enabled=hook_config.get("enabled", True),
                description=hook_config.get("description", ""),
            )
        except Exception as e:
            logger.error(f"Failed to load hook {name}: {e}")
            return None

    async def fire(
        self,
        event: str | HookEvent,
        context: dict | None = None,
        blocking: bool | None = None,
    ) -> None:
        """Fire hooks for an event.

        Args:
            event: The event to fire (string or HookEvent enum)
            context: Context dict passed to hook run() function
            blocking: Override blocking behavior. If None, uses hook config.
        """
        event_str = event.value if isinstance(event, HookEvent) else event
        hooks = self._hooks.get(event_str, [])

        if not hooks:
            return

        ctx = context or {}
        ctx["event"] = event_str
        ctx["timestamp"] = datetime.now(timezone.utc).isoformat()

        for hook in hooks:
            if not hook.enabled:
                continue

            should_block = blocking if blocking is not None else hook.blocking

            if should_block:
                try:
                    await asyncio.wait_for(
                        self._execute(hook, ctx),
                        timeout=hook.timeout,
                    )
                except asyncio.TimeoutError:
                    msg = f"Hook {hook.name} timed out for {event_str}"
                    logger.error(msg)
                    self._record_error(hook.name, event_str, msg)
                except Exception as e:
                    msg = f"Hook {hook.name} failed for {event_str}: {e}"
                    logger.error(msg)
                    self._record_error(hook.name, event_str, str(e))
            else:
                asyncio.create_task(self._safe_execute(hook, ctx))

    async def _execute(self, hook: HookConfig, context: dict) -> None:
        """Execute a hook's run() function."""
        module = self._hook_modules.get(hook.name)
        if not module:
            logger.error(f"Hook module not loaded: {hook.name}")
            return

        run_fn = getattr(module, "run", None)
        if not run_fn:
            logger.error(f"Hook {hook.name} has no run() function")
            return

        if asyncio.iscoroutinefunction(run_fn):
            await run_fn(context)
        else:
            # Sync function - run in executor
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, run_fn, context)

    async def _safe_execute(self, hook: HookConfig, context: dict) -> None:
        """Execute a hook with error isolation (for fire-and-forget)."""
        try:
            await asyncio.wait_for(
                self._execute(hook, context),
                timeout=hook.timeout,
            )
        except asyncio.TimeoutError:
            msg = f"Async hook {hook.name} timed out"
            logger.error(msg)
            self._record_error(hook.name, context.get("event", "?"), msg)
        except Exception as e:
            msg = f"Async hook {hook.name} failed: {e}"
            logger.error(msg)
            self._record_error(hook.name, context.get("event", "?"), str(e))

    def _record_error(self, hook_name: str, event: str, error: str) -> None:
        """Record a hook error for API reporting."""
        self._recent_errors.append(
            HookError(
                hook_name=hook_name,
                event=event,
                error=error,
                timestamp=datetime.now(timezone.utc).isoformat(),
            )
        )

    def get_registered_hooks(self) -> list[dict]:
        """Return all registered hooks for API."""
        seen = set()
        result = []
        for event_hooks in self._hooks.values():
            for hook in event_hooks:
                if hook.name not in seen:
                    seen.add(hook.name)
                    result.append(hook.to_dict())
        return result

    def get_recent_errors(self) -> list[dict]:
        """Return recent hook errors for API."""
        return [e.to_dict() for e in self._recent_errors]

    def health_info(self) -> dict:
        """Return hook health info for /health endpoint."""
        total_hooks = len({h.name for hs in self._hooks.values() for h in hs})
        return {
            "hooks_count": total_hooks,
            "events_registered": list(self._hooks.keys()),
            "recent_errors_count": len(self._recent_errors),
        }
