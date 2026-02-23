"""
Credential loader for sandboxed agent sessions.

Reads flat env-var mappings from vault/.parachute/credentials.yaml and
injects them into container sessions via the stdin JSON payload.

Security notes:
- Credentials are NEVER passed via --env-file or -e flags (docker inspect exposes those)
- Blocked vars prevent overriding auth tokens, PATH, and interpreter internals
- Values are never logged; only key names appear in debug output
- mtime caching avoids repeated file reads on every session start
"""

from pathlib import Path

import yaml

# Env vars that must never be overridden by user-supplied credentials.
_BLOCKED_ENV_VARS: frozenset[str] = frozenset({
    # Auth tokens
    "CLAUDE_CODE_OAUTH_TOKEN",
    # Path / loader hijacking
    "PATH",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    # User identity
    "HOME",
    "USER",
    "SHELL",
    # Python interpreter control — prevent startup-file injection and mode forcing
    "PYTHONPATH",
    "PYTHONSTARTUP",    # Executes a file at interpreter startup (before entrypoint runs)
    "PYTHONINSPECT",    # Forces interactive mode after script completion
    "PYTHONASYNCIODEBUG",
    "PYTHONMALLOC",
    "PYTHONFAULTHANDLER",
    # Node.js execution control
    "NODE_OPTIONS",
})

_cache: dict[str, str] | None = None
_cache_mtime: float = 0.0


def load_credentials(vault_path: Path) -> dict[str, str]:
    """Load credentials from vault/.parachute/credentials.yaml.

    Returns a dict of env-var name → value for all string-valued entries
    that are not in the blocked list.  Returns an empty dict if the file
    does not exist or cannot be parsed.

    Results are cached by file mtime so repeated calls on the same server
    process are cheap.
    """
    global _cache, _cache_mtime

    path = vault_path / ".parachute" / "credentials.yaml"
    if not path.exists():
        return {}

    mtime = path.stat().st_mtime
    if _cache is not None and mtime == _cache_mtime:
        return _cache

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception:
        # Parse error — return stale cache if available, else empty
        return _cache or {}

    result: dict[str, str] = {
        k: str(v)
        for k, v in data.items()
        if isinstance(k, str)
        and isinstance(v, (str, int, float))
        and k not in _BLOCKED_ENV_VARS
        and k  # skip empty keys
    }
    _cache, _cache_mtime = result, mtime
    return result
