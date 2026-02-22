---
status: pending
priority: p2
issue_id: 92
tags: [code-review, testing, trust-levels, architecture]
dependencies: []
---

# Add Explicit Contract Tests for Trust Level Normalization

## Problem Statement

**What's broken/missing:**
The `normalize_trust_level()` function in `computer/parachute/core/trust.py` is a critical architectural seam between legacy and canonical trust values, but has NO dedicated test coverage. It's only tested indirectly through Pydantic config validation.

**Why it matters:**
- This function is the **backward compatibility contract** for trust levels
- Legacy values (`full`, `vault`, `trusted`, `untrusted`) must normalize indefinitely
- A developer could unknowingly remove legacy mappings and break production bot configs
- The normalization layer is security-critical (prevents trust level bypass)

**Evidence:**
- Zero test imports of `normalize_trust_level()` across entire test suite
- Function appears in 8 production files but 0 test files
- PR #99 fixed 7 tests that broke when normalization was introduced, showing the drift

## Findings

**From architecture-strategist (Confidence: 92):**
> The normalization contract (`normalize_trust_level()`) is the architectural seam between legacy and canonical values, but has no dedicated test coverage. This would have caught the drift immediately when the trust level system evolved.

**From python-reviewer (Confidence: 85):**
> Test coverage of normalization: Current tests only cover 30% of the method's code paths when testing through Pydantic validators.

## Proposed Solutions

### Option 1: Create Dedicated Contract Test File (Recommended)
**Effort:** Small (1 hour)
**Risk:** None
**Pros:**
- Clear separation of concerns (contract vs integration)
- Explicit documentation of backward compatibility guarantee
- Fast unit tests (no Pydantic overhead)
- Forces function to remain testable

**Cons:**
- One more test file to maintain

**Implementation:**
```python
# New file: computer/tests/unit/test_trust_normalization.py
from parachute.core.trust import normalize_trust_level, TrustLevelStr
import pytest

class TestNormalizeTrustLevel:
    """Contract tests for trust level normalization."""

    @pytest.mark.parametrize("legacy,canonical", [
        ("full", "direct"),
        ("vault", "direct"),
        ("trusted", "direct"),
        ("untrusted", "sandboxed"),
    ])
    def test_legacy_values_normalize_PERMANENT_CONTRACT(self, legacy, canonical):
        """CRITICAL: Legacy values must normalize for backward compatibility."""
        assert normalize_trust_level(legacy) == canonical

    @pytest.mark.parametrize("canonical", ["direct", "sandboxed"])
    def test_canonical_values_passthrough(self, canonical):
        """Canonical values are identity mappings."""
        assert normalize_trust_level(canonical) == canonical

    def test_unknown_value_raises_clear_error(self):
        """Unknown values fail fast with actionable message."""
        with pytest.raises(ValueError, match="Unknown trust level.*Valid values"):
            normalize_trust_level("invalid")

    def test_case_insensitive(self):
        """Normalization handles mixed case input."""
        assert normalize_trust_level("FULL") == "direct"
        assert normalize_trust_level("SandBoxed") == "sandboxed"
```

### Option 2: Add to Existing test_trust_levels.py
**Effort:** Small (30 minutes)
**Risk:** None
**Pros:**
- No new file
- Co-located with other trust level tests

**Cons:**
- Mixes contract tests with trust model tests
- Less clear what's being tested

### Option 3: Do Nothing
**Effort:** None
**Risk:** Medium
**Pros:**
- No work required

**Cons:**
- Technical debt remains
- Future breaking changes could go unnoticed
- Missing test coverage for security-critical path

## Recommended Action

**Choose Option 1** - Create dedicated contract test file

**Justification:**
- Clear architectural intent (this is a CONTRACT, not just a helper function)
- Verbose test names document backward compatibility guarantee
- Would have prevented the 7-test drift in PR #99
- Sets precedent for testing other normalization layers

## Technical Details

**Affected files:**
- `computer/parachute/core/trust.py` (function being tested)
- `computer/tests/unit/test_trust_normalization.py` (new file)

**Database changes:** None

**API changes:** None

## Acceptance Criteria

- [ ] New test file created: `computer/tests/unit/test_trust_normalization.py`
- [ ] All 4 legacy value mappings tested with parametrized test
- [ ] Canonical value pass-through tested
- [ ] Invalid value error handling tested
- [ ] Case-insensitive normalization tested
- [ ] All tests pass
- [ ] Test names include "PERMANENT_CONTRACT" to discourage removal

## Work Log

*Add dated entries as work progresses*

## Resources

- Issue: #92
- PR: #99 (the test fixes that revealed this gap)
- Function: `computer/parachute/core/trust.py:27-48`
- Architecture review finding: Confidence 92%
- Related: Bot connector config validation uses this function
