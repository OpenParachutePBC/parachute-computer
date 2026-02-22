"""
Contract tests for trust level normalization.

CRITICAL: These tests document the permanent backward compatibility contract
for trust level values. Legacy values must normalize indefinitely to maintain
compatibility with existing bot configurations.
"""

from parachute.core.trust import normalize_trust_level, TrustLevelStr
import pytest


class TestNormalizeTrustLevel:
    """Contract tests for trust level normalization.

    These tests enforce the backward compatibility contract between legacy
    trust values (full, vault, trusted, untrusted) and canonical values
    (direct, sandboxed).
    """

    @pytest.mark.parametrize("legacy,canonical", [
        ("full", "direct"),
        ("vault", "direct"),
        ("trusted", "direct"),
        ("untrusted", "sandboxed"),
    ])
    def test_legacy_values_normalize_PERMANENT_CONTRACT(self, legacy, canonical):
        """CRITICAL: Legacy values must normalize for backward compatibility.

        This is a PERMANENT CONTRACT. Removing or changing these mappings will
        break production bot configurations. Legacy values must normalize
        indefinitely.
        """
        assert normalize_trust_level(legacy) == canonical, \
            f"Legacy {legacy!r} must normalize to {canonical!r}"

    @pytest.mark.parametrize("canonical", ["direct", "sandboxed"])
    def test_canonical_values_passthrough(self, canonical):
        """Canonical values are identity mappings."""
        assert normalize_trust_level(canonical) == canonical, \
            f"Canonical value {canonical!r} should pass through unchanged"

    def test_unknown_value_raises_clear_error(self):
        """Unknown values fail fast with actionable message."""
        with pytest.raises(ValueError, match="Unknown trust level.*Valid values"):
            normalize_trust_level("invalid")

    @pytest.mark.parametrize("mixed_case,expected", [
        ("FULL", "direct"),
        ("Full", "direct"),
        ("VAULT", "direct"),
        ("Vault", "direct"),
        ("SANDBOXED", "sandboxed"),
        ("SandBoxed", "sandboxed"),
        ("DIRECT", "direct"),
        ("Direct", "direct"),
    ])
    def test_case_insensitive_normalization(self, mixed_case, expected):
        """Normalization handles mixed case input."""
        assert normalize_trust_level(mixed_case) == expected, \
            f"Mixed case {mixed_case!r} should normalize to {expected!r}"

    def test_empty_string_raises_error(self):
        """Empty string is not a valid trust level."""
        with pytest.raises(ValueError, match="Unknown trust level"):
            normalize_trust_level("")

    def test_none_like_raises_error(self):
        """None-like values raise clear errors."""
        with pytest.raises((ValueError, AttributeError)):
            normalize_trust_level(None)
