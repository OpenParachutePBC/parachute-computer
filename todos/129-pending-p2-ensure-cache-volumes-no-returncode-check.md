---
status: pending
priority: p2
issue_id: 96
tags: [code-review, python, reliability, sandbox]
dependencies: []
---

# `_ensure_cache_volumes()` Does Not Check `docker volume create` Return Code

## Problem Statement

`_ensure_cache_volumes()` creates named Docker volumes (`parachute-pip-cache`, `parachute-npm-cache`) but does not check the return code of the `docker volume create` subprocess. If volume creation fails (e.g., Docker daemon is unavailable, disk full, permission denied), the method logs "cache volumes ready" regardless and execution continues. Subsequent container creation will either silently fail to mount the volume or create an empty anonymous volume, with no diagnostic information available.

## Findings

- **Sources**: python-reviewer (confidence 88), pattern-recognition-specialist (confidence 85)
- **Location**: `computer/parachute/core/sandbox.py`, `_ensure_cache_volumes()` method (~lines 487-509)
- **Evidence**:
  ```python
  async def _ensure_cache_volumes(self) -> None:
      for vol_name in ["parachute-pip-cache", "parachute-npm-cache"]:
          proc = await asyncio.create_subprocess_exec(
              "docker", "volume", "create", vol_name,
              stdout=asyncio.subprocess.PIPE,
              stderr=asyncio.subprocess.PIPE,
          )
          await proc.communicate()
          # Missing: if proc.returncode != 0: raise/log error
      logger.info("cache volumes ready")  # Always logs success
  ```

## Proposed Solutions

### Solution A: Check returncode and log stderr on failure (Recommended)
```python
async def _ensure_cache_volumes(self) -> None:
    for vol_name in ["parachute-pip-cache", "parachute-npm-cache"]:
        proc = await asyncio.create_subprocess_exec(
            "docker", "volume", "create", vol_name,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            logger.warning(f"Failed to create volume {vol_name}: {stderr.decode().strip()}")
        else:
            logger.debug(f"Volume {vol_name} ready")
    logger.info("cache volumes ready")
```
- **Pros**: Operator knows when volume creation fails; easier debugging
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

### Solution B: Raise on failure to prevent container creation with missing volumes
Make the missing volume a hard error that prevents the container from starting.
- **Pros**: Fail-fast behavior; clear error
- **Cons**: A Docker volume creation failure (transient) blocks the entire sandbox
- **Effort**: Small
- **Risk**: Low to medium (may be too strict for a cache that's an optimization)

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`
- **Note**: `docker volume create` is idempotent — it returns exit 0 if the volume already exists. The returncode would only be non-zero on a genuine failure.

## Acceptance Criteria

- [ ] `_ensure_cache_volumes()` logs a warning (or raises) when `docker volume create` returns non-zero
- [ ] The success log message is not printed when a volume fails to create

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | Every subprocess call should check returncode; Docker operations are especially prone to silent failures |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
