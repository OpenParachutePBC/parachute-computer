---
status: pending
priority: p1
issue_id: 96
tags: [code-review, architecture, docker, sandbox]
dependencies: []
---

# Capability Mounts Still Mount to Old `/vault/` Path

## Problem Statement

The PR migrates the vault mount from `/vault` to `/home/sandbox/Parachute` in `_build_mounts()` and `ensure_default_container()`, but `_build_capability_mounts()` was NOT updated. This means sandboxed containers have the vault at `/home/sandbox/Parachute` but capability files (MCPs, skills, agents, CLAUDE.md) are mounted into the container at non-existent `/vault/` paths. Sandboxed agents will fail to find their MCPs, skills, and agent definitions at runtime — effectively neutering sandboxed agent capabilities.

## Findings

- **Sources**: pattern-recognition-specialist (confidence 92), architecture-strategist (confidence 95), parachute-conventions-reviewer (confidence 97)
- **Location**: `computer/parachute/core/sandbox.py`, `_build_capability_mounts()` method (~lines 188-203)
- **Evidence**:
  ```python
  # In _build_capability_mounts() — NOT updated by this PR:
  mounts.extend(["-v", f"{mcp_json}:/vault/.mcp.json:ro"])
  mounts.extend(["-v", f"{skills_dir}:/vault/.skills:ro"])
  mounts.extend(["-v", f"{agents_dir}:/vault/.parachute/agents:ro"])
  mounts.extend(["-v", f"{claude_md}:/vault/CLAUDE.md:ro"])
  ```
  But the vault is now mounted at `/home/sandbox/Parachute`, so `/vault/` does not exist in the container.
- **Also**: `orchestrator.py` (~lines 779-780) constructs `PARACHUTE_CWD` with `/vault/` prefix for sandbox containers — also not updated by this PR.

## Proposed Solutions

### Solution A: Update `_build_capability_mounts()` to use new path (Recommended)
Replace all `/vault/` prefixes in `_build_capability_mounts()` with `/home/sandbox/Parachute/`.

```python
mounts.extend(["-v", f"{mcp_json}:/home/sandbox/Parachute/.mcp.json:ro"])
mounts.extend(["-v", f"{skills_dir}:/home/sandbox/Parachute/.skills:ro"])
mounts.extend(["-v", f"{agents_dir}:/home/sandbox/Parachute/.parachute/agents:ro"])
mounts.extend(["-v", f"{claude_md}:/home/sandbox/Parachute/CLAUDE.md:ro"])
```

Also update `orchestrator.py` lines 779-780 to use `/home/sandbox/Parachute/` prefix.

- **Pros**: Consistent path convention, agents find their capabilities
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

### Solution B: Define a `CONTAINER_VAULT_PATH` constant
Extract the container-side vault path as a module-level constant used in both `_build_mounts()` and `_build_capability_mounts()`.

```python
CONTAINER_VAULT_PATH = "/home/sandbox/Parachute"
```

- **Pros**: DRY, prevents future divergence
- **Cons**: Slightly more refactor than needed
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**:
  - `computer/parachute/core/sandbox.py` — `_build_capability_mounts()` method
  - `computer/parachute/core/orchestrator.py` — lines 779-780 (PARACHUTE_CWD construction)
- **Components**: DockerSandbox, SessionOrchestrator

## Acceptance Criteria

- [ ] All mounts in `_build_capability_mounts()` use `/home/sandbox/Parachute/` as the container-side path
- [ ] `orchestrator.py` constructs `PARACHUTE_CWD` using `/home/sandbox/Parachute/` prefix
- [ ] A sandboxed agent can find its MCP config at `/home/sandbox/Parachute/.mcp.json`
- [ ] A sandboxed agent can find its skills at `/home/sandbox/Parachute/.skills/`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | Vault path migration must be applied to ALL mount sites — _build_capability_mounts() and orchestrator.py were missed |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
