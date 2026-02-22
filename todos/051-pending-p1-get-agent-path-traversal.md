---
status: pending
priority: p1
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# GET /agents/{name} Missing Name Validation — Path Traversal

## Problem Statement

The `GET /agents/{name}` endpoint constructs a file path from user-supplied `name` without calling `_validate_agent_name()`. All other agent CRUD endpoints (create, upload, delete) validate via regex, but the read endpoint was missed. An attacker can traverse directories to read any `.md` file on the filesystem via the `system_prompt` response field.

## Findings

- **Source**: security-sentinel (P1, confidence 95), pattern-recognition-specialist (P2, confidence 92)
- **Location**: `computer/parachute/api/agents.py:141-158`
- **Evidence**: `agent_file = agents_dir / f"{name}.md"` with no preceding `_validate_agent_name(name)` call. The `.md` suffix limits which files can be read, but any `.md` file on the filesystem is reachable (CLAUDE.md, module prompts, etc.)

## Proposed Solutions

### Solution A: Add validation call (Recommended)
Add `_validate_agent_name(name)` at the top of `get_agent`. One-line fix.
- **Pros**: Consistent with create/upload/delete, zero regression risk
- **Cons**: None
- **Effort**: Small (1 line)
- **Risk**: None

### Solution B: Add resolved path check
After constructing the path, verify `agent_file.resolve().relative_to(agents_dir.resolve())`.
- **Pros**: Defense-in-depth even if regex is bypassed
- **Cons**: Slightly more complex, redundant with regex
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `computer/parachute/api/agents.py` — API layer

## Acceptance Criteria

- [ ] `GET /agents/{name}` calls `_validate_agent_name(name)` before filesystem access
- [ ] Requests with `../` or special chars in name return 400

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | One of four CRUD endpoints missed validation |

## Resources

- PR: #75
- Related: Security fix S1 in the deepened plan already addressed create/upload/delete
