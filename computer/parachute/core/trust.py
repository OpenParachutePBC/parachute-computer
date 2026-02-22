"""
Canonical trust level normalization.

Single source of truth for mapping all trust level strings (legacy and current)
to the two canonical values: "direct" and "sandboxed".

Previously, 5-6 inline dicts scattered across the codebase did this mapping
individually, creating drift risk. Import from here instead.
"""

from typing import Literal

TrustLevelStr = Literal["direct", "sandboxed"]

_NORMALIZE_MAP: dict[str, TrustLevelStr] = {
    # Canonical values
    "direct": "direct",
    "sandboxed": "sandboxed",
    # Legacy values — accepted indefinitely for backward compatibility
    "trusted": "direct",
    "untrusted": "sandboxed",
    "full": "direct",
    "vault": "direct",
}


def normalize_trust_level(value: str) -> TrustLevelStr:
    """Normalize any trust level string to the canonical form.

    Raises ValueError for unrecognized values rather than silently passing
    them through (which would cause an opaque Pydantic validation error).

    Args:
        value: Trust level string in any supported format.

    Returns:
        "direct" or "sandboxed".

    Raises:
        ValueError: If value is not a recognized trust level string.
    """
    normalized = _NORMALIZE_MAP.get(value.lower() if value else "")
    if normalized is None:
        valid = ", ".join(sorted(_NORMALIZE_MAP.keys()))
        raise ValueError(
            f"Unknown trust level: {value!r}. Valid values: {valid}"
        )
    return normalized
