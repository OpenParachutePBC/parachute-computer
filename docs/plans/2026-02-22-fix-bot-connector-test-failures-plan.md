---
title: fix(tests): Bot connector test failures
type: fix
date: 2026-02-22
issue: 92
---

# Fix Bot Connector Test Failures

## Enhancement Summary

**Deepened on:** 2026-02-22
**Research agents used:** python-reviewer, code-simplicity-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist, best-practices-researcher, Explore

### Key Improvements from Research
1. **Critical async signature issue identified** - Test needs both `@pytest.mark.asyncio` AND correct method signature match
2. **Missing second assertion in Fix #7** - Matrix test checks two fields but plan only updates one
3. **Discord test can be improved** - Current fix doesn't test meaningful Discord behavior
4. **Fixture extraction opportunity** - `TestConnector` class repeated 4+ times
5. **Parametrization opportunities** - Trust level normalization tests can be consolidated
6. **Trust level migration test missing** - No test verifies backward compatibility behavior itself

### Research Confidence Scores
- Async pattern correctness: 95%
- Trust level validator testing: 88%
- Discord config test improvement: 92%
- Test isolation concerns: 82%

---

## Problem

7 tests in `computer/tests/unit/test_bot_connectors.py` are failing due to code evolution that wasn't reflected in the tests:

1. **Trust level normalization** — Tests expect old values (`"vault"`, `"full"`, `"untrusted"`) but config now normalizes to `"direct"` or `"sandboxed"`
2. **Async signature change** — `get_trust_level()` became async but test calls it synchronously
3. **Router prefix change** — Test expects `"/api/bots"` but router only defines `"/bots"` (parent adds `/api`)
4. **Discord config field** — Test uses non-existent `allowed_guilds` field (should be `allowed_users`)

All failures are pre-existing and unrelated to recent PRs. They block confidence in future bot connector development.

## Root Causes

### 1. Trust Level Normalization (5 tests)

**Affected tests:**
- `TestBotsConfig::test_default_config` (line 166)
- `TestBotsConfig::test_full_config_parsing` (line 204)
- `TestMatrixConfig::test_default_config` (line 602)
- `TestMatrixConfig::test_trust_level_normalization` (line 626)

**Root cause:**
Trust level system evolved from three-tier (`full`, `vault`, `sandboxed`) to binary (`direct`, `sandboxed`) with backward-compatible normalization in `computer/parachute/core/trust.py`:

```python
_NORMALIZE_MAP: dict[str, TrustLevelStr] = {
    "direct": "direct",      # Canonical
    "sandboxed": "sandboxed", # Canonical
    "trusted": "direct",      # Legacy
    "untrusted": "sandboxed", # Legacy
    "full": "direct",         # Legacy
    "vault": "direct",        # Legacy
}
```

Pydantic validators in `connectors/config.py` apply normalization on input, so stored values are always canonical. Tests assert against old values.

### 2. Async Method Not Awaited (1 test)

**Affected test:**
- `TestBotConnectorBase::test_get_trust_level` (line 292)

**Root cause:**
`BotConnector.get_trust_level()` signature changed from sync to async but test calls it without `await`:

```python
# Test code (broken)
assert connector.get_trust_level("dm") == "vault"

# Returns: <coroutine object BotConnector.get_trust_level at 0x...>
```

Test needs `@pytest.mark.asyncio` decorator and `await` keyword.

**Critical finding from python-reviewer (95% confidence):** The method signature at `base.py:393` is:
```python
async def get_trust_level(self, chat_type: str, user_id: str | None = None) -> str:
```

The test must match this signature exactly, not just add `await` to the old signature.

### 3. Router Prefix Mismatch (1 test)

**Affected test:**
- `TestConnectorImports::test_api_router_importable` (line 337)

**Root cause:**
API architecture changed to stack prefixes:

- `bots.py:64` defines: `router = APIRouter(prefix="/bots")`
- `api/__init__.py:34` includes: `api_router.include_router(bots.router)`
- Main router at `__init__.py:14` defines: `api_router = APIRouter(prefix="/api")`
- **Final path:** `/api/bots/*` (stacked)

Test imports `bots.router` directly and checks `router.prefix`, which is just `"/bots"`, not the full path.

### 4. Discord Config Field Error (1 test)

**Affected test:**
- `TestBotsConfig::test_discord_config` (line 186)

**Root cause:**
Test constructs `DiscordConfig` with `allowed_guilds=["guild1", "guild2"]` but this field doesn't exist. Discord config uses `allowed_users` (list of user IDs), not guilds.

This appears to be a test copy-paste error or outdated pattern.

## Proposed Solution

Update tests to match current implementation patterns:

1. **Update trust level assertions** to expect normalized canonical values
2. **Add async test decorator and await** for async method call with correct signature
3. **Fix router prefix assertion** to check local prefix only
4. **Improve Discord test** to verify actual Discord config behavior

## Implementation

### File: `computer/tests/unit/test_bot_connectors.py`

#### Fix 1: `test_default_config` (line 166)

**Change:**
```python
# Before
assert config.telegram.dm_trust_level == "vault"

# After
assert config.telegram.dm_trust_level == "sandboxed", \
    "Default dm_trust_level should be normalized to 'sandboxed'"
```

**Research insight:** Add assertion messages for clearer test failure output (python-reviewer, 95% confidence).

#### Fix 2: `test_discord_config` (lines 180-186)

**Enhanced fix from research (92% confidence):**
```python
# Before
config = DiscordConfig(
    enabled=True,
    bot_token="test-token",
    allowed_guilds=["guild1", "guild2"],  # ❌ Field doesn't exist
)
assert config.enabled
assert len(config.allowed_guilds) == 2

# After (improved to test actual Discord behavior)
def test_discord_config(self):
    """Test Discord configuration with user allowlist and normalization."""
    config = DiscordConfig(
        enabled=True,
        bot_token="test-token",
        allowed_users=["discord_user_1", "discord_user_2"],
        dm_trust_level="full",  # Legacy value to test normalization
        group_mention_mode="all_messages",
    )
    assert config.enabled
    assert config.bot_token == "test-token"
    assert len(config.allowed_users) == 2
    assert config.dm_trust_level == "direct", "Legacy 'full' should normalize to 'direct'"
    assert config.group_mention_mode == "all_messages"
```

**Why this is better:** Tests actual Discord fields AND trust level normalization in context, rather than just asserting `enabled=True`.

#### Fix 3: `test_full_config_parsing` (line 204)

**Change:**
```python
# Before
assert config.telegram.dm_trust_level == "full"

# After
assert config.telegram.dm_trust_level == "direct", \
    "Legacy 'full' should normalize to 'direct'"
```

#### Fix 4: `test_get_trust_level` (lines 281-292) - CRITICAL UPDATE

**Enhanced fix with correct signature (python-reviewer, 95% confidence):**
```python
# Before
def test_get_trust_level(self):
    class TestConnector(BotConnector):
        # ... setup code ...

    connector = TestConnector(
        bot_token="test",
        server=None,
        allowed_users=[],
        dm_trust_level="vault",
        group_trust_level="sandboxed",
    )
    assert connector.get_trust_level("dm") == "vault"
    assert connector.get_trust_level("group") == "sandboxed"

# After (with correct async signature and state verification)
@pytest.mark.asyncio
async def test_get_trust_level(self):
    """Test trust level retrieval for different chat types."""
    class TestConnector(BotConnector):
        platform = "test"
        async def start(self): pass
        async def stop(self): pass
        async def on_text_message(self, update, context): pass
        async def _run_loop(self): pass

    connector = TestConnector(
        bot_token="test",
        server=None,
        allowed_users=[],
        dm_trust_level="direct",  # Use normalized value
        group_trust_level="sandboxed",
    )

    # Verify no leaked state (python-reviewer, 82% confidence)
    assert connector._trust_overrides == {}, "Should start with empty trust overrides"

    # Test both chat types with correct async signature
    dm_level = await connector.get_trust_level("dm")
    assert dm_level == "direct", f"Expected 'direct' for DM, got {dm_level!r}"

    group_level = await connector.get_trust_level("group")
    assert group_level == "sandboxed", f"Expected 'sandboxed' for group, got {group_level!r}"
```

**Key improvements:**
- Uses `@pytest.mark.asyncio` decorator
- Awaits the coroutine properly
- Uses normalized canonical values (`"direct"` not `"vault"`)
- Adds state isolation check (`_trust_overrides`)
- Adds descriptive assertion messages

#### Fix 5: `test_api_router_importable` (line 337)

**Enhanced fix (parachute-conventions, 85% confidence):**
```python
# Before
assert router.prefix == "/api/bots"

# After (with clarifying comment)
def test_api_router_importable(self):
    """Verify bots router is importable with correct configuration."""
    from parachute.api.bots import router

    assert router is not None, "Router should be importable"
    # Router's own prefix (not the full stacked path /api/bots)
    assert router.prefix == "/bots", "Router local prefix should be '/bots'"
    assert "bots" in router.tags, "Router should have 'bots' tag"
```

**Why clarify:** The test name suggests full API path but checks local prefix only. Comment prevents confusion.

#### Fix 6: `test_default_config` (Matrix, line 602)

**Change:**
```python
# Before
assert config.dm_trust_level == "untrusted"

# After
assert config.dm_trust_level == "sandboxed", \
    "Default should normalize legacy 'untrusted' to 'sandboxed'"
```

#### Fix 7: `test_trust_level_normalization` (Matrix, line 626) - CRITICAL UPDATE

**Complete fix with missing assertion (parachute-conventions, 88% confidence):**
```python
# Before
config = MatrixConfig(
    dm_trust_level="full",
    group_trust_level="sandboxed",
)
assert config.dm_trust_level == "trusted"  # ❌ Wrong - expects old mapping

# After (complete fix)
def test_trust_level_normalization(self):
    """Test legacy trust level strings normalize to canonical values."""
    config = MatrixConfig(
        dm_trust_level="full",          # Legacy → normalizes to "direct"
        group_trust_level="sandboxed",  # Already canonical
    )
    assert config.dm_trust_level == "direct", \
        "Legacy 'full' should normalize to 'direct'"
    assert config.group_trust_level == "sandboxed", \
        "'sandboxed' is already canonical"  # Missing assertion added

    # Test other legacy mappings for completeness
    config2 = MatrixConfig(
        dm_trust_level="vault",         # Legacy → "direct"
        group_trust_level="untrusted",  # Legacy → "sandboxed"
    )
    assert config2.dm_trust_level == "direct", \
        "Legacy 'vault' should normalize to 'direct'"
    assert config2.group_trust_level == "sandboxed", \
        "Legacy 'untrusted' should normalize to 'sandboxed'"
```

**Critical finding:** The current test at line 627 checks both `dm_trust_level` and `group_trust_level`, but the plan only fixed one assertion. This fix addresses both.

## Testing Strategy

### Research Insights

**From python-reviewer (confidence: 95):**
- Use `pytest.mark.asyncio` for all async tests
- Add descriptive assertion messages for debugging
- Verify test isolation (no leaked state between tests)
- Use `AsyncMock()` from unittest.mock for async method mocking

**From best-practices-researcher:**
- pytest-asyncio 1.0+ uses automatic event loop management
- `AsyncClient` preferred over `TestClient` for async FastAPI tests
- Field validators should use `mode="before"` for normalization
- Always test both valid and invalid validator inputs

### Verification Steps

1. **Run the specific failing tests:**
   ```bash
   cd computer
   source .venv/bin/activate
   python -m pytest tests/unit/test_bot_connectors.py::TestBotsConfig::test_default_config \
                    tests/unit/test_bot_connectors.py::TestBotsConfig::test_discord_config \
                    tests/unit/test_bot_connectors.py::TestBotsConfig::test_full_config_parsing \
                    tests/unit/test_bot_connectors.py::TestBotConnectorBase::test_get_trust_level \
                    tests/unit/test_bot_connectors.py::TestConnectorImports::test_api_router_importable \
                    tests/unit/test_bot_connectors.py::TestMatrixConfig::test_default_config \
                    tests/unit/test_bot_connectors.py::TestMatrixConfig::test_trust_level_normalization \
                    -v
   ```

2. **Run full test suite to ensure no regressions:**
   ```bash
   python -m pytest tests/unit/test_bot_connectors.py -v
   ```

3. **Verify all 92 tests pass**

### Expected Results

- ✅ All 7 previously failing tests pass
- ✅ All 85 already-passing tests continue to pass
- ✅ Total: 92/92 tests pass
- ✅ Test execution time remains < 1 second

## Acceptance Criteria

- [x] `TestBotsConfig::test_default_config` passes with normalized trust level assertion
- [x] `TestBotsConfig::test_discord_config` passes with valid config fields and tests normalization
- [x] `TestBotsConfig::test_full_config_parsing` passes with normalized trust level assertion
- [x] `TestBotConnectorBase::test_get_trust_level` passes as async test with correct signature and await
- [x] `TestConnectorImports::test_api_router_importable` passes with correct prefix assertion and tag check
- [x] `TestMatrixConfig::test_default_config` passes with normalized trust level assertion
- [x] `TestMatrixConfig::test_trust_level_normalization` passes with BOTH assertions (dm and group)
- [x] All 92 tests in `test_bot_connectors.py` pass
- [x] No new test failures introduced
- [x] Test execution time remains < 5 seconds (actual: 4.55s for full suite, 0.23s for 7 fixes)
- [x] All assertions include descriptive error messages

## Impact Analysis

**Scope:** Test-only changes, no production code affected

**Risk:** Minimal
- Only modifying assertions in test file
- No changes to bot connector implementation
- No API or configuration changes

**Benefits:**
- Unblocks confident bot connector development
- Foundation for #89 (production hardening) implementation
- Validates that trust level normalization is working correctly
- Improves test clarity with assertion messages and comments

## Research Insights

### Best Practices Applied

**Async Testing (from best-practices-researcher):**
- Use `@pytest.mark.asyncio` decorator for async test functions
- Always `await` async method calls
- pytest-asyncio 1.0+ handles event loop automatically
- Use `AsyncMock()` for mocking async methods

**Pydantic Validation Testing:**
- Test validators by constructing models with various inputs
- Use `mode="before"` for normalization validators
- Test both valid and invalid inputs
- Check error messages in ValidationError exceptions

**Trust Level Patterns (from Explore agent):**
- Single source of truth: `parachute/core/trust.py`
- Normalization function raises ValueError with clear message
- Field validators delegate to `normalize_trust_level()`
- Test both legacy and canonical values

### Pattern Recognition Findings

**From pattern-recognition-specialist (confidence: 88):**

1. **Test Anti-Patterns Fixed:**
   - Hardcoded magic values → Using canonical normalized values
   - Async/sync impedance mismatch → Proper async test decoration
   - Testing implementation details → Clarified with comments
   - Copy-paste test duplication → Improved Discord test

2. **Opportunities Identified:**
   - Extract `TestConnector` class to shared fixture (repeated 4+ times)
   - Parametrize trust level normalization tests
   - Add test for backward compatibility behavior
   - Consider test data builder pattern for complex configs

3. **Naming Improvements:**
   - Added docstrings to clarify test purpose
   - Assertion messages explain expected behavior
   - Comments explain architectural decisions (prefix stacking)

### Established Codebase Patterns

**From Explore agent - trust level testing patterns:**

1. **Normalization function:**
   ```python
   from parachute.core.trust import normalize_trust_level
   normalized = normalize_trust_level("full")  # Returns "direct"
   ```

2. **Field validator pattern:**
   ```python
   @field_validator("dm_trust_level", mode="before")
   @classmethod
   def normalize_trust(cls, v: str) -> str:
       return normalize_trust_level(v)
   ```

3. **Test fixture pattern:**
   ```python
   @pytest.fixture
   def test_vault(tmp_path: Path) -> Path:
       vault = tmp_path / "test-vault"
       vault.mkdir()
       return vault
   ```

4. **YAML config test pattern:**
   ```python
   def test_load_from_yaml(self, tmp_path):
       parachute_dir = tmp_path / ".parachute"
       parachute_dir.mkdir()
       (parachute_dir / "bots.yaml").write_text("...")
       config = load_bots_config(tmp_path)
       assert config.telegram.enabled
   ```

## Future Improvements (Not in Scope)

**From code-simplicity-reviewer (confidence: 88):**

1. **Extract TestConnector to fixture** (Medium effort, Medium impact)
   - Create shared `minimal_bot_connector` fixture in conftest.py
   - Saves ~15 LOC, improves maintainability
   - Pattern already exists in codebase at `tests/conftest.py`

2. **Parametrize trust level tests** (Medium effort, Medium impact)
   ```python
   @pytest.mark.parametrize("input_value,expected", [
       ("direct", "direct"),
       ("sandboxed", "sandboxed"),
       ("full", "direct"),
       ("vault", "direct"),
       ("trusted", "direct"),
       ("untrusted", "sandboxed"),
   ])
   def test_trust_level_normalization(input_value, expected):
       config = TelegramConfig(dm_trust_level=input_value)
       assert config.dm_trust_level == expected
   ```

3. **Add backward compatibility migration test** (Low effort, High impact)
   - Explicitly tests that legacy values normalize correctly
   - Documents the backward compatibility guarantee
   - Prevents regression if normalization is changed

## References

### Internal
- Issue #92: Bug report with initial analysis
- Issue #89: Bot framework production hardening (blocked by these test failures)
- `computer/parachute/core/trust.py:13-48` — Trust level normalization implementation
- `computer/parachute/connectors/config.py:31-34` — Pydantic validator using normalization
- `computer/parachute/connectors/base.py:393` — Async `get_trust_level()` method signature
- `computer/parachute/api/bots.py:64` — Router prefix definition
- `computer/parachute/api/__init__.py:14,34` — Main API router prefix stacking
- `computer/tests/conftest.py:21-26` — Async test fixture configuration
- `computer/tests/unit/test_trust_levels.py` — Established trust level testing patterns
- `computer/tests/unit/test_workspaces.py:105-114` — Workspace trust level update patterns

### External Best Practices
- [pytest-asyncio 1.0+ Concepts](https://pytest-asyncio.readthedocs.io/en/latest/concepts.html)
- [Pydantic v2 Validators](https://docs.pydantic.dev/latest/concepts/validators/)
- [FastAPI Testing Documentation](https://fastapi.tiangolo.com/tutorial/testing/)
- [Async Test Patterns for Pytest](https://tonybaloney.github.io/posts/async-test-patterns-for-pytest-and-unittest.html)

### Related Plans
- Multi-agent workspace teams plan — Trust level enforcement patterns
- Bot connector resilience plan — Async lifecycle management patterns
- Server error propagation plan — Async streaming and error handling
