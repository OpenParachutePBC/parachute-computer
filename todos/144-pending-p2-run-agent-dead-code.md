---
status: pending
priority: p2
issue_id: 107
tags: [code-review, security, dead-code, sandbox]
dependencies: []
---

# Remove Dead `run_agent()` Method with Latent Credential Leak

## Problem Statement

**What's broken/missing:**
`DockerSandbox.run_agent()` (sandbox.py:422-459) is defined but has zero callers. The orchestrator exclusively uses `run_persistent()` and `run_default()`. More critically, `run_agent()` does NOT apply the `BOT_SOURCES` credential gate — if it were ever called for a bot session, host credentials would be injected.

**Why it matters:**
- Dead code with a security flaw: if reactivated without noticing, credentials would leak to bot sessions
- The docstring on `_stream_process` still references it, creating confusion about architecture
- 38 lines of code maintained for no benefit

## Findings

**From code-simplicity-reviewer (Confidence: 95):**
> `run_agent` has no callers and has a latent credential leak. Remove entirely.

**From git-history-analyzer (Confidence: 97):**
> `_run_in_container()` is the shared helper used by `run_persistent()` and `run_default()`. `run_agent()` bypasses it entirely, missing the credential gate.

**Verified:** `grep -rn "run_agent(" computer/` returns only the definition, zero callsites.

## Proposed Solution

Remove `DockerSandbox.run_agent()` (lines 422-459 in sandbox.py) and update the `_stream_process` docstring which references it.

**Effort:** Small
**Risk:** None — zero callsites confirmed

## Acceptance Criteria
- [ ] `run_agent()` method removed from `DockerSandbox`
- [ ] `_stream_process` docstring updated (no longer mentions `run_agent`)
- [ ] All tests still pass

## Resources
- File: `computer/parachute/core/sandbox.py:422-459`
- Verified dead: `grep -rn "run_agent(" computer/ --include="*.py"` → definition only
