---
status: pending
priority: p3
issue_id: 107
tags: [code-review, security, docker, sandbox]
dependencies: []
---

# Improve `_ensure_sandbox_network()` Exit Code & Error Handling

## Problem Statement

**What's broken/missing:**
`_ensure_sandbox_network()` discards stderr and treats any exit code 1 as "already exists" — but Docker returns exit code 1 for multiple failure modes including permission errors and daemon unavailability. A transient Docker daemon error during network creation is silently ignored.

**Why it matters:**
- A container might attach to the wrong network or fail in unexpected ways if network creation fails silently
- There's also no process-level guard: on cold start with many workspaces, N parallel `docker network create` subprocesses fire simultaneously (though Docker handles this safely)

## Findings

**From security-sentinel (Confidence: 82):**
> Docker returns exit code 1 for both "already exists" and various transient daemon errors. Discarding stderr means these can't be distinguished.

**From performance-oracle (Confidence: 92):**
> No process-level `_network_created` flag. After first successful creation, subsequent calls still spawn a subprocess (only at container creation time, not per-message).

## Proposed Solutions

**Solution A: Capture stderr and verify "already exists" message**
```python
async def _ensure_sandbox_network(self) -> None:
    proc = await asyncio.create_subprocess_exec(
        "docker", "network", "create", "--driver", "bridge", SANDBOX_NETWORK_NAME,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode not in (0, 1):
        raise RuntimeError(f"Failed to create sandbox network: {stderr.decode().strip()}")
    if proc.returncode == 1 and "already exists" not in stderr.decode():
        raise RuntimeError(f"Unexpected network creation error: {stderr.decode().strip()}")
```

**Solution B: Add `_network_created: bool` instance flag**
After first successful creation (exit 0), set `self._network_created = True` and skip subprocess on subsequent calls. Reset in cleanup paths.

**Effort:** Small
**Risk:** Very low

## Acceptance Criteria
- [ ] Transient Docker daemon errors (not "already exists") raise an exception or log a warning
- [ ] Successful network creation doesn't result in redundant subprocess calls on subsequent sessions

## Resources
- File: `computer/parachute/core/sandbox.py` (around `_ensure_sandbox_network`)
