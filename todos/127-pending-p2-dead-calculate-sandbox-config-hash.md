---
status: pending
priority: p2
issue_id: 96
tags: [code-review, quality, python]
dependencies: []
---

# Dead `calculate_sandbox_config_hash()` Function in `workspace.py` Hashes Wrong Fields

## Problem Statement

The PR adds `calculate_sandbox_config_hash()` to `models/workspace.py` but this function is never called anywhere in the codebase. The config hash functionality is already implemented as `_calculate_config_hash()` inside `DockerSandbox` in `sandbox.py`, which is the one actually used. The `workspace.py` version also hashes the wrong inputs: it includes `timeout` (irrelevant to container identity — timeout can change without requiring a container rebuild) and excludes `SANDBOX_IMAGE` (critical — if the image tag changes, existing containers must be rebuilt). Dead code in a wrong module with incorrect semantics.

## Findings

- **Sources**: pattern-recognition-specialist (confidence 97), code-simplicity-reviewer (confidence 95), python-reviewer (confidence 92)
- **Location**: `computer/parachute/models/workspace.py`, lines 179-195
- **Evidence**:
  ```python
  # workspace.py — DEAD CODE, never called
  def calculate_sandbox_config_hash(config: SandboxConfig) -> str:
      config_dict = config.model_dump(mode="json")  # includes timeout, memory, cpu
      config_json = json.dumps(config_dict, sort_keys=True)
      hash_digest = hashlib.sha256(config_json.encode()).hexdigest()
      return hash_digest[:12]

  # sandbox.py — LIVE CODE, actually used
  def _calculate_config_hash(self) -> str:
      raw = f"{SANDBOX_IMAGE}:{CONTAINER_MEMORY_LIMIT}:{CONTAINER_CPU_LIMIT}"
      return hashlib.sha256(raw.encode()).hexdigest()[:12]
  ```
  The two functions hash different inputs and produce incompatible digests. Also, `import hashlib` and `import json` in `workspace.py` are only present for this dead function.

## Proposed Solutions

### Solution A: Delete `calculate_sandbox_config_hash()` from `workspace.py` (Recommended)
Remove the function and its two unused imports (`hashlib`, `json`).
- **Pros**: Eliminates dead code, removes confusion about which function is authoritative
- **Cons**: None — it is never called
- **Effort**: Small
- **Risk**: Low

### Solution B: Consolidate and fix the hash function
Fix the `workspace.py` function to hash the same inputs as `sandbox.py`, then wire it up as the single source of truth.
- **Pros**: DRY if we want workspace-level configuration to trigger container rebuild
- **Cons**: Over-engineering — the `sandbox.py` implementation is simpler and already works
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/models/workspace.py`
- **Dead imports**: `hashlib`, `json` (both only used by this function)

## Acceptance Criteria

- [ ] `calculate_sandbox_config_hash()` removed from `workspace.py`
- [ ] `import hashlib` and `import json` removed from `workspace.py` (they have no other callers)
- [ ] `grep -r "calculate_sandbox_config_hash"` returns no results

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | When adding a function, immediately wire it up — orphaned functions signal design uncertainty |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
