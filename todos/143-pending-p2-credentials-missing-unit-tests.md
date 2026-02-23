---
status: pending
priority: p2
issue_id: 107
tags: [code-review, security, testing, credentials, sandbox]
dependencies: []
---

# Add Unit Tests for Credential Security Gates

## Problem Statement

**What's broken/missing:**
No unit tests verify that `CLAUDE_CODE_OAUTH_TOKEN` is blocked by `_BLOCKED_ENV_VARS`, or that bot sessions receive empty credentials. The credential injection system is security-critical but completely untested.

**Why it matters:**
- If someone accidentally removes `CLAUDE_CODE_OAUTH_TOKEN` from `_BLOCKED_ENV_VARS`, the only protection is CI — but there are no tests covering this invariant
- The `BOT_SOURCES` gate in `_run_in_container` is a trust boundary with no test coverage
- These are the highest-consequence code paths in the credential injection feature

## Findings

**From parachute-conventions-reviewer (Confidence: 85):**
> No test verifies `CLAUDE_CODE_OAUTH_TOKEN` is blocked by `_BLOCKED_ENV_VARS`, or that bot-sourced `AgentSandboxConfig` results in `stdin_payload["credentials"] == {}`

**From security-sentinel (Confidence: 92):**
> `_BLOCKED_ENV_VARS` has no runtime assertion confirming blocked keys were encountered

## Proposed Solutions

**Solution A: Targeted unit tests in `test_trust_levels.py` (Recommended)**
- Add `test_load_credentials_blocks_oauth_token` — write a tmp credentials.yaml containing `CLAUDE_CODE_OAUTH_TOKEN: leaked`, assert `load_credentials()` returns `{}`
- Add `test_load_credentials_blocks_pythonstartup` — same for PYTHONSTARTUP
- Add `test_bot_session_gets_empty_credentials` — construct `AgentSandboxConfig(session_source=SessionSource.TELEGRAM)`, mock `_run_in_container`, assert `credentials == {}`
- Add `test_app_session_gets_credentials` — same with `SessionSource.APP`, assert credentials passed through

**Effort:** Small
**Risk:** None — adding tests only

## Acceptance Criteria
- [ ] `load_credentials()` returns empty dict when CLAUDE_CODE_OAUTH_TOKEN is in YAML
- [ ] `load_credentials()` returns empty dict when PYTHONSTARTUP is in YAML
- [ ] Bot sessions (TELEGRAM, DISCORD, MATRIX) result in `credentials == {}`
- [ ] App sessions with matching vault file result in credentials being passed through
- [ ] `session_source=None` (unknown caller) also results in `credentials == {}`

## Resources
- File: `computer/parachute/lib/credentials.py`
- File: `computer/parachute/core/sandbox.py` (credential gate at line ~732)
- Existing tests: `computer/tests/unit/test_trust_levels.py`
