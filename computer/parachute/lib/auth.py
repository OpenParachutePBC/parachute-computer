"""
API key authentication for Parachute server.

Provides secure key generation, hashing, and validation for multi-device access.
"""

import hashlib
import secrets
from dataclasses import dataclass
from datetime import datetime
from typing import Optional


# Key format: para_<32 random chars>
KEY_PREFIX = "para_"
KEY_LENGTH = 32  # Random part length


@dataclass
class APIKey:
    """Represents an API key with metadata."""

    id: str  # k_<first 12 chars of key>
    label: str
    key_hash: str  # sha256:<hash>
    created_at: datetime
    last_used_at: Optional[datetime] = None

    def to_dict(self) -> dict:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "label": self.label,
            "key_hash": self.key_hash,
            "created_at": self.created_at.isoformat(),
            "last_used_at": self.last_used_at.isoformat() if self.last_used_at else None,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "APIKey":
        """Create from dictionary."""
        return cls(
            id=data["id"],
            label=data["label"],
            key_hash=data["key_hash"],
            created_at=datetime.fromisoformat(data["created_at"]),
            last_used_at=datetime.fromisoformat(data["last_used_at"]) if data.get("last_used_at") else None,
        )


def generate_key() -> tuple[str, str]:
    """
    Generate a new API key.

    Returns:
        tuple of (full_key, key_id)
        - full_key: The complete key to give to the user (para_...)
        - key_id: The ID for display/revocation (k_...)
    """
    random_part = secrets.token_urlsafe(KEY_LENGTH)[:KEY_LENGTH]
    full_key = f"{KEY_PREFIX}{random_part}"
    key_id = f"k_{random_part[:12]}"
    return full_key, key_id


def hash_key(key: str) -> str:
    """
    Hash an API key for secure storage.

    Args:
        key: The full API key (para_...)

    Returns:
        Hash string in format sha256:<hex>
    """
    key_bytes = key.encode("utf-8")
    hash_bytes = hashlib.sha256(key_bytes).hexdigest()
    return f"sha256:{hash_bytes}"


def verify_key(provided_key: str, stored_hash: str) -> bool:
    """
    Verify a provided key against a stored hash.

    Args:
        provided_key: The key provided by the client
        stored_hash: The hash stored in config

    Returns:
        True if the key matches
    """
    if not provided_key or not stored_hash:
        return False

    computed_hash = hash_key(provided_key)
    return secrets.compare_digest(computed_hash, stored_hash)


def extract_key_id(key: str) -> str:
    """
    Extract the key ID from a full key.

    Args:
        key: Full API key (para_...)

    Returns:
        Key ID (k_...)
    """
    if not key.startswith(KEY_PREFIX):
        raise ValueError(f"Invalid key format: must start with {KEY_PREFIX}")

    random_part = key[len(KEY_PREFIX):]
    return f"k_{random_part[:12]}"


def create_api_key(label: str) -> tuple[APIKey, str]:
    """
    Create a new API key with metadata.

    Args:
        label: Human-readable label for the key (e.g., "iPhone 15 Pro")

    Returns:
        tuple of (APIKey object, plaintext_key)
        The plaintext key should be shown to the user exactly once.
    """
    full_key, key_id = generate_key()

    api_key = APIKey(
        id=key_id,
        label=label,
        key_hash=hash_key(full_key),
        created_at=datetime.utcnow(),
    )

    return api_key, full_key
