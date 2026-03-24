---
title: "Test suite audit: cut dead weight, add safety rails, fill real gaps"
type: refactor
date: 2026-03-24
issue: 339
---

# Test Suite Audit

Cut ~4,500 lines of dead/redundant test code, add timeout protection, and refocus testing on fast feedback and regression catching.

## Problem Statement

Tests are timing out and running too long. Investigation reveals the root cause isn't slow infrastructure — it's accumulated test code for features that are punted, removed, or over-tested. The suite has grown to 63 files / ~14,000 lines across Python and Flutter, but much of that doesn't protect code we're actively shipping.

**Current state:**
- 10,330 lines of Python tests across 40 files
- 3,714 lines of Flutter tests across 17 unit + 5 integration files
- No `pytest-timeout` — tests can hang indefinitely
- No CI — tests only run when someone remembers
- Bot connector tests (2,251 lines) for a punted feature
- Skills/agents API tests (158 lines) for a feature being removed
- 6 Flutter disposal tests (~1,350 lines) that were written to chase a specific bug

## Testing Philosophy

Optimize for:
1. **Fast feedback** — full suite runs in <30 seconds locally
2. **Catch regressions, not prove correctness** — we're iterating fast
3. **Test boundaries, not internals** — API contracts > helper function unit tests

## Acceptance Criteria

- [x] Dead test code removed (bot connectors, skills agents API, Flutter disposal duplication)
- [x] `pytest-timeout` added with 30s global default
- [x] Makefile has `test-fast` (unit only) and `test-all` (everything) targets
- [x] Python tests run in <15s with `make test-fast`
- [x] Flutter disposal tests consolidated to 1 file
- [x] No test hangs indefinitely

---

## Phase 1: Remove Dead Weight

### Python — Delete

| File | Lines | Reason |
|------|-------|--------|
| `tests/unit/test_bot_connectors.py` | 2,251 | Feature punted. Biggest timeout culprit (5-10s wait_for calls accumulate). Rewrite when feature resumes. |
| `tests/integration/test_skills_agents_api.py` | 158 | Feature being removed. Requires running test server. Has 120s timeouts. |
| `tests/e2e/test_chat_flow.py` | 247 | Requires ANTHROPIC_API_KEY, already skipped in most runs. Real E2E should live in CI when we have it, not local. |

Also remove from `conftest.py`:
- `minimal_bot_connector` fixture (lines 157-190) — only used by bot connector tests

**Total removed: ~2,656 Python lines**

### Python — Evaluate for trimming

| File | Lines | Question |
|------|-------|----------|
| `test_credentials.py` | 1,243 | Is the credential system actively used? Issue #300 says "audit needed". If punted, delete. If active, keep but review for stdlib-testing bloat. |
| `test_trust_levels.py` | 488 | Trust levels are core — keep, but check if sandbox/Docker tests still reflect current architecture. |
| `test_sandbox_transcript.py` | 396 | Is sandbox transcript loading still the active mechanism? If so, keep. |

### Flutter — Consolidate disposal tests

Currently 6 files (~1,350 lines):
- `chat_screen_disposal_test.dart` (469)
- `full_chat_disposal_test.dart` (285)
- `markdown_disposal_test.dart` (235)
- `message_bubble_disposal_test.dart` (130)
- `message_bubble_isolate_test.dart` (130)
- `minimal_repro_test.dart` (97)

**Action:** Consolidate into one `disposal_lifecycle_test.dart` (~200 lines) that tests the key disposal pattern once with a representative widget tree. Delete the rest.

### Flutter — Evaluate builder tests

These 3 files (~507 lines) look like exploration/debugging artifacts:
- `with_builders_test.dart` (204)
- `builder_variants_test.dart` (185)
- `builder_providerscope_test.dart` (118)

**Action:** Review if any of these test real app behavior. If they're just experimenting with Riverpod patterns, delete them.

**Estimated total reduction: ~4,500 lines (34% of test code)**

---

## Phase 2: Add Safety Rails

### 2a. Add `pytest-timeout`

In `pyproject.toml`:
```toml
[project.optional-dependencies]
dev = [
    "pytest>=7.4.0",
    "pytest-asyncio>=0.21.0",
    "pytest-timeout>=2.2.0",
    "httpx>=0.25.0",
]

[tool.pytest.ini_options]
timeout = 30
```

This gives every test a 30s hard ceiling. Any test that needs more is probably testing too much.

### 2b. Improve Makefile targets

```makefile
test-fast: $(VENV)              ## Run unit tests only (fast)
	$(BIN)/python -m pytest tests/unit/ tests/core/ -x -q

test: $(VENV)                   ## Run all tests
	$(BIN)/pip install -e ".[dev]" -q
	$(BIN)/python -m pytest tests/ -v

test-integration: $(VENV)       ## Run integration tests (needs server)
	$(BIN)/python -m pytest tests/integration/ -v
```

Default developer workflow becomes `make test-fast`. Full suite for pre-commit/PR.

### 2c. Fix session-scoped event loop

The current `event_loop` fixture is session-scoped, which can leak state between tests. Modern pytest-asyncio (0.21+) handles this automatically. Remove the manual fixture from `conftest.py` — let the framework manage it.

---

## Phase 3: Fill Real Gaps

After cutting and hardening, assess what's actually under-tested for the features we're shipping:

### Priority coverage gaps

| Area | Current Coverage | Gap |
|------|-----------------|-----|
| **API contract tests** | 3 basic integration tests (health, modules, sessions) | Need tests for chat, daily, and brain API response shapes |
| **Module loading** | `test_plugin_discovery.py` covers plugins | No test that modules actually load and register correctly |
| **Brain graph schema** | `test_brain_api.py` covers CRUD | No migration/schema evolution test |
| **Config loading** | `test_config_yaml.py` (161 lines) | Good, keep as-is |
| **Session lifecycle** | `test_session_manager.py` (222 lines) | Good, keep as-is |

### What NOT to add

- Don't add tests for bot connectors until the feature resumes
- Don't add E2E tests until we have CI to run them
- Don't add unit tests for internal helpers — test the API boundary instead

---

## Implementation Order

1. **Delete dead tests** — zero risk, immediate improvement
2. **Add pytest-timeout** — one-line protection against hangs
3. **Update Makefile** — better developer workflow
4. **Consolidate Flutter disposal tests** — reduce noise
5. **Remove event loop fixture** — let pytest-asyncio manage it
6. **Evaluate credentials/trust/sandbox tests** — with Aaron, decide keep vs trim
7. **Add API contract tests** — only after dust settles from cuts

## Dependencies & Risks

- **Risk: Removing tests for code that's still used** — Mitigated by reviewing each file against current architecture before deleting. Bot connectors and skills API are confirmed punted/removed.
- **Risk: pytest-timeout breaks legitimate slow tests** — The 30s default is generous. Any test hitting it was already a problem.
- **Risk: Flutter disposal bugs resurface** — Keep one consolidated test that covers the core pattern. The 6 files are redundant, not the concept.

## References

- Current test config: `computer/pyproject.toml`, `computer/Makefile`
- Main fixtures: `computer/tests/conftest.py`
- Issue #300: Credential system audit (related — informs whether to keep `test_credentials.py`)
