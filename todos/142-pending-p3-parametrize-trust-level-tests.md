---
status: pending
priority: p3
issue_id: 92
tags: [code-review, testing, refactoring, duplication]
dependencies: []
---

# Parametrize Trust Level Normalization Tests

## Problem Statement

**What's broken/missing:**
Trust level normalization is tested separately for Telegram, Discord, and Matrix configs with identical assertion logic, creating ~30 LOC of duplication across 7+ test methods.

**Why it matters:**
- Same normalization logic tested 7+ times in different methods
- Adding new platforms or legacy values requires updating multiple tests
- Duplication makes tests harder to maintain
- Inconsistent coverage across platforms

**Evidence:**
- Pattern recognition found 7+ similar assertions (Confidence: 90%)
- Lines affected: 166-168, 186-193, 211-212, 625-628, 646-665
- All test identical normalization behavior with different config classes

## Findings

**From pattern-recognition-specialist (Confidence: 90):**
> Parametrization Opportunity: Trust Level Assertions
> - Trust level normalization tested separately for Telegram, Discord, Matrix
> - 7+ similar assertions with identical logic
> - Consolidates into 1 parametrized test
> - Reduces ~30 LOC

**Current pattern:**
```python
# Telegram test
assert config.telegram.dm_trust_level == "sandboxed"

# Discord test
assert config.dm_trust_level == "direct"  # from "full"

# Matrix test
assert config.dm_trust_level == "direct"  # from "full"
assert config.group_trust_level == "sandboxed"  # from "untrusted"
```

## Proposed Solutions

### Option 1: Parametrize Across All Platforms (Recommended)
**Effort:** Small (45 minutes)
**Risk:** None
**Pros:**
- Single source of truth for normalization testing
- Easy to add new platforms (just add row to parameters)
- Easy to test new legacy values
- Reduces ~30 LOC
- Makes normalization contract explicit

**Cons:**
- Slightly less obvious which platform is being tested
- Parametrized tests can be harder to debug

**Implementation:**
```python
@pytest.mark.parametrize("config_class,field,input_value,expected", [
    (TelegramConfig, "dm_trust_level", "full", "direct"),
    (TelegramConfig, "dm_trust_level", "vault", "direct"),
    (TelegramConfig, "dm_trust_level", "untrusted", "sandboxed"),
    (TelegramConfig, "dm_trust_level", "direct", "direct"),  # Canonical passthrough
    (DiscordConfig, "dm_trust_level", "full", "direct"),
    (DiscordConfig, "group_trust_level", "untrusted", "sandboxed"),
    (MatrixConfig, "dm_trust_level", "full", "direct"),
    (MatrixConfig, "dm_trust_level", "vault", "direct"),
    (MatrixConfig, "group_trust_level", "untrusted", "sandboxed"),
    (MatrixConfig, "group_trust_level", "sandboxed", "sandboxed"),  # Canonical
])
def test_trust_level_normalization_across_platforms(
    config_class, field, input_value, expected
):
    """All platform configs normalize trust levels consistently."""
    config = config_class(**{field: input_value})
    actual = getattr(config, field)
    assert actual == expected, \
        f"Legacy {input_value!r} should normalize to {expected!r}, got {actual!r}"
```

### Option 2: Keep Platform-Specific Tests
**Effort:** None
**Risk:** Low
**Pros:**
- Clear which platform each test covers
- Easier to debug failures
- Self-contained tests

**Cons:**
- Duplication persists (~30 LOC)
- Harder to ensure consistency across platforms
- Adding new platform requires copy-paste

### Option 3: Parametrize Per-Platform
**Effort:** Medium (1 hour)
**Risk:** None
**Pros:**
- Balance between parametrization and clarity
- Each platform has its own parametrized test

**Cons:**
- Partial solution (still some duplication)
- More complex than Option 1

## Recommended Action

**Choose Option 1** - Parametrize across all platforms

**Justification:**
- Normalization behavior should be platform-agnostic
- Makes it trivial to add new platforms or test new legacy values
- Plan document already identified this pattern (lines 476-489)
- Follows pytest best practices

## Technical Details

**Affected files:**
- `computer/tests/unit/test_bot_connectors.py`

**Tests to consolidate:**
- `TestBotsConfig::test_default_config` (line 166-168)
- `TestBotsConfig::test_discord_config` (line 186-193)
- `TestBotsConfig::test_full_config_parsing` (line 211-212)
- `TestMatrixConfig::test_default_config` (line 625-628)
- `TestMatrixConfig::test_trust_level_normalization` (line 646-665)

**New parametrized test:**
- `test_trust_level_normalization_across_platforms` (single method, 10+ parameter sets)

**Database changes:** None

**API changes:** None

## Acceptance Criteria

- [ ] Single parametrized test created covering all platforms
- [ ] At least 10 parameter combinations tested (Telegram, Discord, Matrix)
- [ ] Covers: defaults, legacy values, canonical pass-through
- [ ] Old duplicate assertions removed from platform-specific tests
- [ ] All 92 tests still pass
- [ ] LOC reduction: ~25-30 lines

## Work Log

*Add dated entries as work progresses*

## Resources

- Issue: #92
- PR: #99
- Pattern recognition finding: Confidence 90%
- Plan document: Lines 476-489 (already identified this pattern)
- pytest docs: https://docs.pytest.org/en/latest/how-to/parametrize.html
