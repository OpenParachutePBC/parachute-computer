---
status: pending
priority: p3
issue_id: 92
tags: [code-review, testing, refactoring, duplication]
dependencies: []
---

# Extract TestConnector Class to Shared Fixture

## Problem Statement

**What's broken/missing:**
The same `TestConnector` class is defined inline **5 times** in `test_bot_connectors.py` with nearly identical structure, creating ~40 LOC of duplication.

**Why it matters:**
- Duplication makes tests harder to maintain
- When `BotConnector` interface changes, must update 5 places
- Inconsistent implementations could cause subtle test bugs

**Evidence:**
- Pattern recognition specialist found 5 instances (Confidence: 95%)
- Total duplication: ~40 LOC across lines 253, 270, 288, 314, 371
- 4 of 5 definitions are byte-for-byte identical

## Findings

**From pattern-recognition-specialist (Confidence: 95):**
> TestConnector Class Duplication: 5 Instances
> - 5 class definitions
> - ~8 LOC per definition = 40 LOC of duplication
> - Identical structure across 4 of the 5 instances

**From code-simplicity-reviewer (Confidence: 88):**
> The plan correctly identified fixture extraction opportunity but underestimated scope (5 instances, not 4+)

## Proposed Solutions

### Option 1: Extract to conftest.py Fixture (Recommended)
**Effort:** Small (30 minutes)
**Risk:** None
**Pros:**
- Single source of truth
- Reduces ~40 LOC
- Available to all test files
- Follows pytest best practices

**Cons:**
- One more fixture to understand
- Slightly less explicit than inline definition

**Implementation:**
```python
# computer/tests/conftest.py
@pytest.fixture
def minimal_bot_connector():
    """Minimal BotConnector subclass for unit testing base functionality."""
    class TestConnector(BotConnector):
        platform = "test"
        async def start(self): pass
        async def stop(self): pass
        async def on_text_message(self, update, context): pass
        async def _run_loop(self): pass
    return TestConnector

# Usage in tests:
def test_is_user_allowed_int(minimal_bot_connector):
    connector = minimal_bot_connector(
        bot_token="test",
        server=None,
        allowed_users=[123, 456],
    )
    assert connector.is_user_allowed(123)
```

### Option 2: Keep Inline Definitions
**Effort:** None
**Risk:** Low
**Pros:**
- Tests are self-contained
- No external dependencies

**Cons:**
- Duplication persists
- Maintenance burden when `BotConnector` interface changes

## Recommended Action

**Choose Option 1** - Extract to conftest.py

**Justification:**
- Pattern already exists in conftest.py (other fixtures present)
- Reduces LOC and improves maintainability
- Plan document already identified this (just underestimated count)

## Technical Details

**Affected files:**
- `computer/tests/conftest.py` (add fixture)
- `computer/tests/unit/test_bot_connectors.py` (remove 5 inline definitions)

**Lines to update:**
- Line 253: `test_is_user_allowed_int`
- Line 270: `test_is_user_allowed_string`
- Line 288: `test_get_trust_level`
- Line 314: `test_status_enriched_fields`
- Line 371: `_make_test_connector` (factory function, slightly different)

**Database changes:** None

**API changes:** None

## Acceptance Criteria

- [ ] Fixture added to `computer/tests/conftest.py`
- [ ] All 5 inline `TestConnector` definitions removed
- [ ] Tests updated to use fixture parameter
- [ ] All 92 tests still pass
- [ ] LOC reduction: ~35-40 lines

## Work Log

*Add dated entries as work progresses*

## Resources

- Issue: #92
- PR: #99
- Pattern recognition finding: Confidence 95%, identified 5 instances
- Plan document: Lines 467-474 (already identified but undercounted)
- Reference: `computer/tests/conftest.py` for fixture patterns
