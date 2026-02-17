---
status: pending
priority: p1
issue_id: 33
tags: [code-review, security, docker]
dependencies: []
---

# Ephemeral Containers Missing Security Hardening

## Problem Statement

Persistent containers get `--cap-drop ALL`, `--pids-limit 100`, `--security-opt no-new-privileges`, and `--init` flags, but ephemeral containers (the `_build_run_args` path) do not apply the same hardening. This creates an inconsistent security posture — ephemeral containers are actually less hardened than persistent ones.

## Findings

- **Source**: security-sentinel (H1), parachute-conventions-reviewer (F5)
- **Location**: `computer/parachute/core/sandbox.py` — `_build_run_args()` method
- **Evidence**: `_create_persistent_container()` includes `--cap-drop ALL`, `--pids-limit 100`, `--security-opt no-new-privileges`, `--init`. The `_build_run_args()` method used for ephemeral containers does not include these flags.

## Proposed Solutions

### Solution A: Add hardening flags to `_build_run_args` (Recommended)
Add the same security flags to the ephemeral path.
- **Pros**: Simple, direct, consistent security posture
- **Cons**: None
- **Effort**: Small
- **Risk**: Low — these flags are standard Docker hardening

### Solution B: Extract shared security flags to a constant
Define `SECURITY_FLAGS = ["--cap-drop", "ALL", "--pids-limit", "100", ...]` and use in both paths.
- **Pros**: DRY, ensures future parity
- **Cons**: Slight over-engineering for 4 flags
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`
- **Components**: DockerSandbox._build_run_args()

## Acceptance Criteria

- [ ] Ephemeral containers include `--cap-drop ALL`
- [ ] Ephemeral containers include `--pids-limit 100`
- [ ] Ephemeral containers include `--security-opt no-new-privileges`
- [ ] Ephemeral containers include `--init`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | Security hardening should be consistent across all container types |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
- Issue #33: https://github.com/OpenParachutePBC/parachute-computer/issues/33
