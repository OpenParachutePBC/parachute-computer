#!/usr/bin/env python3
"""
Context Hook - re-injects profile context before compaction.

Triggered by Claude SDK's PreCompact hook. Reads vault/.parachute/profile.md
and outputs it so Claude includes it in the compacted context.

Usage: python -m parachute.hooks.context_hook
       (SDK passes hook input via stdin)

Hook Configuration (in .claude/settings.json):
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "python -m parachute.hooks.context_hook"
          }
        ]
      }
    ]
  }
}
"""

import json
import sys
from pathlib import Path


def main():
    """Entry point - read hook input from stdin and output context for injection."""
    try:
        json.loads(sys.stdin.read())
    except (json.JSONDecodeError, OSError):
        return

    try:
        from parachute.config import get_settings
        settings = get_settings()
        vault_path = settings.vault_path
    except Exception:
        # Fallback: standard vault location
        vault_path = Path.home() / "Parachute"

    profile_path = vault_path / ".parachute" / "profile.md"

    if not profile_path.exists():
        return

    content = profile_path.read_text(encoding="utf-8").strip()
    if not content:
        return

    # Output as a context reminder block — Claude includes this pre-compaction
    print(
        f"\n---\n"
        f"## Persistent Context (re-injected before compaction)\n\n"
        f"{content}\n"
        f"---\n"
    )


if __name__ == "__main__":
    main()
