"""
Hooks API endpoints.

Returns SDK hooks configured in .claude/settings.json. The HookRunner
(internal event bus) is kept only for error tracking.
"""

import json
import logging
from typing import Any

from fastapi import APIRouter

from parachute.config import get_settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/hooks", tags=["hooks"])

# Module-level state (set during server startup)
_hook_runner: Any = None


def init_hooks_api(hook_runner: Any) -> None:
    """Initialize hooks API with the active HookRunner (kept for internal error tracking)."""
    global _hook_runner
    _hook_runner = hook_runner


def _load_sdk_hooks() -> list[dict[str, Any]]:
    """Load SDK hook configurations from .claude/settings.json."""
    settings = get_settings()

    # SDK hooks live in the vault's .claude/settings.json
    settings_path = settings.vault_path / ".claude" / "settings.json"
    if not settings_path.exists():
        return []

    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Failed to read .claude/settings.json: {e}")
        return []

    hooks_config = data.get("hooks", {})
    if not isinstance(hooks_config, dict):
        return []

    result: list[dict[str, Any]] = []
    for event_name, hook_list in hooks_config.items():
        if not isinstance(hook_list, list):
            continue
        for hook in hook_list:
            if not isinstance(hook, dict):
                continue
            result.append({
                "name": hook.get("command", "unknown"),
                "events": [event_name],
                "blocking": event_name.startswith("PreTool") or event_name.startswith("pre"),
                "description": f"SDK hook: {hook.get('command', '')}",
                "type": "sdk",
                "matcher": hook.get("matcher"),
            })

    return result


@router.get("")
async def list_hooks():
    """List all hooks (SDK hooks from .claude/settings.json)."""
    sdk_hooks = _load_sdk_hooks()

    return {
        "hooks": sdk_hooks,
        "health": {
            "hooks_count": len(sdk_hooks),
            "type": "sdk",
            "recent_errors_count": len(_hook_runner.get_recent_errors()) if _hook_runner else 0,
        },
    }


@router.get("/errors")
async def hook_errors():
    """Get recent hook errors (from internal event bus)."""
    if not _hook_runner:
        return {"errors": []}

    return {
        "errors": _hook_runner.get_recent_errors(),
    }
