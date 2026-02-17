---
status: pending
priority: p1
issue_id: 33
tags: [code-review, security, validation]
dependencies: []
---

# Workspace Slug Not Validated in sandbox.py

## Problem Statement

`workspace_slug` is passed directly into Docker container names and labels without validation inside `sandbox.py`. While the orchestrator may sanitize upstream, defense-in-depth requires validation at the boundary where it's used in shell commands. A malicious or malformed slug could lead to command injection or unexpected Docker behavior.

## Findings

- **Source**: parachute-conventions-reviewer (F1), python-reviewer
- **Location**: `computer/parachute/core/sandbox.py` — `ensure_container()`, `_create_persistent_container()`
- **Evidence**: `container_name = f"parachute-sandbox-{workspace_slug}"` used directly in subprocess calls without validating that `workspace_slug` matches `^[a-zA-Z0-9_-]+$` or similar pattern.

## Proposed Solutions

### Solution A: Add slug validation at sandbox.py boundary (Recommended)
Add a validation check at the top of `ensure_container()` that raises `ValueError` if slug doesn't match `^[a-zA-Z0-9_-]+$`.
- **Pros**: Defense-in-depth, fails fast with clear error
- **Cons**: Duplicates upstream validation (if any)
- **Effort**: Small
- **Risk**: Low

### Solution B: Use a sanitize function that strips invalid chars
Instead of rejecting, sanitize the slug by removing invalid characters.
- **Pros**: More permissive
- **Cons**: Could silently create unexpected container names, harder to debug
- **Effort**: Small
- **Risk**: Medium — silent mutation is risky

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`
- **Components**: DockerSandbox.ensure_container(), _create_persistent_container()

## Acceptance Criteria

- [ ] `workspace_slug` validated against `^[a-zA-Z0-9_-]+$` before use in Docker commands
- [ ] Invalid slugs raise `ValueError` with descriptive message
- [ ] Validation happens at the sandbox.py boundary (not just upstream)

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | Always validate at the boundary where values are used in commands |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
- Issue #33: https://github.com/OpenParachutePBC/parachute-computer/issues/33
