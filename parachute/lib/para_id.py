"""
Para ID generation for unique message/paragraph identifiers.

Format: para:xxxxxxxx (8 character base36 string)
"""

import random
import string
import time

# Base36 characters
BASE36_CHARS = string.digits + string.ascii_lowercase


def generate_para_id() -> str:
    """
    Generate a unique paragraph ID.

    Format: para:xxxxxxxx
    Uses timestamp + random component for uniqueness.
    """
    # Use current time in milliseconds as base
    timestamp = int(time.time() * 1000)

    # Add random component
    random_part = random.randint(0, 1679615)  # max 4 base36 digits

    # Combine and convert to base36
    combined = (timestamp % 1679616) * 1679616 + random_part  # Keep it to 8 chars

    # Convert to base36
    result = []
    for _ in range(8):
        result.append(BASE36_CHARS[combined % 36])
        combined //= 36

    return f"para:{''.join(reversed(result))}"


def parse_para_id(para_id: str) -> dict[str, str] | None:
    """
    Parse a para ID string.

    Returns dict with 'prefix' and 'id' keys, or None if invalid.
    """
    if not para_id or not para_id.startswith("para:"):
        return None

    parts = para_id.split(":", 1)
    if len(parts) != 2 or len(parts[1]) != 8:
        return None

    return {"prefix": parts[0], "id": parts[1]}


def is_valid_para_id(para_id: str) -> bool:
    """Check if a string is a valid para ID."""
    if not para_id or not para_id.startswith("para:"):
        return False

    parts = para_id.split(":", 1)
    if len(parts) != 2 or len(parts[1]) != 8:
        return False

    # Check all characters are valid base36
    return all(c in BASE36_CHARS for c in parts[1])
