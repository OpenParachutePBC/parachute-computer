"""
Shared validators for workspace slugs and sandbox paths.

Extracted to avoid circular imports between peer modules
(sandbox.py, workspaces.py, orchestrator.py).
"""

import re

_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$")


def validate_workspace_slug(slug: str) -> None:
    """Validate a workspace slug. Raises ValueError on invalid input."""
    if not slug or "/" in slug or "\\" in slug or ".." in slug:
        raise ValueError(f"Invalid workspace slug: {slug!r}")
    if not _SLUG_PATTERN.match(slug):
        raise ValueError(f"Invalid workspace slug: {slug!r}")
