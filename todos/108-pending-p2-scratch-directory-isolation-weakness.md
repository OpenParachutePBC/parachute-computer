---
status: pending
priority: p2
issue_id: 62
tags: [code-review, security, sandbox, documentation]
created: 2026-02-21
---

# Scratch Directory Isolation Weakness in Shared Default Container

## Problem Statement

Per-session scratch directories created at `/scratch/{session_id}/` provide organizational separation but not true security isolation. All sessions running in the same container (particularly `parachute-default`) share UID 1000 (sandbox user), allowing any session to read/write other sessions' scratch directories.

**Impact:** Medium - In the shared default container, a malicious agent could:
- List `/scratch/` to discover other session IDs
- Read temporary data from concurrent/previous sessions
- Potentially poison scratch directories for future sessions

This is **NOT exploitable for container escape** or host access, but violates session isolation within the container.

**Introduced in:** Commit 8f93d13 (feat: per-session scratch dirs)

## Findings

**Source:** Security Sentinel (Confidence: 87)

**Current implementation:**
```python
# entrypoint.py:109-110
scratch_dir = f"/scratch/{session_id}"
os.makedirs(scratch_dir, exist_ok=True)
# No explicit mode set - defaults to 0o777 & ~umask
```

**Container UID:**
```dockerfile
# Dockerfile.sandbox
USER sandbox  # UID 1000
```

**Docker mount:**
```python
# sandbox.py:212, 511, 698
"--tmpfs", "/scratch:size=512m,uid=1000,gid=1000"
```

**Why this is a problem:**
1. All containers run as `sandbox` user (UID 1000)
2. Default `mkdir` creates directories with mode 0o755 (world-readable)
3. Same UID can access all files under `/scratch/`
4. No kernel-level isolation between sessions

**Attack scenario:**
```python
# Session A (malicious)
import os
print(os.listdir("/scratch"))  # ["session-abc", "session-def", "session-xyz"]
with open("/scratch/session-def/api_response.json") as f:
    stolen_data = f.read()
```

## Proposed Solutions

### Solution 1: Document Limitation + Explicit 0o700 (Recommended for v1)

**Approach:** Acknowledge this as a known limitation for single-user local deployment. Add explicit permissions as defense-in-depth.

**Implementation:**
```python
# entrypoint.py:109-110
scratch_dir = f"/scratch/{session_id}"
os.makedirs(scratch_dir, mode=0o700, exist_ok=True)  # Explicit rwx------

# Add comment:
# NOTE: All sessions share UID 1000 (sandbox user), so 0o700 provides
# organizational separation but not true multi-tenant isolation.
# Acceptable for single-user local product. For production multi-user
# deployments, use per-session ephemeral containers instead of shared
# persistent containers.
```

**Pros:**
- Minimal code change
- Documents the limitation clearly
- Explicit mode is best practice even if ineffective here

**Cons:**
- Doesn't actually prevent access (same UID)
- Still organizational, not security isolation

**Effort:** Minimal (15 minutes)
**Risk:** None

### Solution 2: Per-Session Ephemeral Containers (Future Architecture)

**Approach:** Use ephemeral containers (`run_agent()`) instead of shared persistent container for true session isolation.

**Pros:**
- True kernel-level isolation per session
- Each session gets its own UID namespace

**Cons:**
- 2-3 second startup latency per session (vs instant with shared container)
- Higher resource usage (N containers vs 1 shared)
- Defeats purpose of default container performance optimization

**Effort:** Large (this is a different architecture)
**Risk:** Medium

### Solution 3: Dynamic UID Allocation (Future Enhancement)

**Approach:** Dynamically create a unique UID per session inside the container.

**Implementation:**
```python
# In entrypoint, before scratch dir creation:
session_uid = 2000 + hash(session_id) % 1000  # UID 2000-2999
os.setuid(session_uid)  # Requires root in container to change UID
```

**Pros:**
- True multi-session isolation within single container

**Cons:**
- Requires container to run as root initially (security risk)
- Complex UID management
- Breaks SDK which expects UID 1000

**Effort:** Large
**Risk:** High

## Recommended Action

Implement **Solution 1** immediately - document the limitation and add explicit `mode=0o700` as defense-in-depth. This is appropriate for the current use case (single-user local deployment).

For future multi-user/hosted deployments, evaluate **Solution 2** (ephemeral containers per session) as the architectural fix.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/docker/entrypoint.py:109-110`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/sandbox.py:212, 511, 698`

**Threat model:**
- **In scope:** Malicious agent code running in shared default container
- **Out of scope:** Container escape to host (already prevented by Docker isolation)

**Mitigation factors:**
- tmpfs is ephemeral (cleared on container restart)
- Single-user local deployment (user trusts their own agents)
- Workspace containers are 1:1 (no sharing)

**Components:**
- Docker sandbox entrypoint
- Default container (`parachute-default`)

**Database changes:** None

## Acceptance Criteria

- [ ] Add explicit `mode=0o700` to `os.makedirs()` in entrypoint.py
- [ ] Add comment documenting UID sharing limitation
- [ ] Update `core/sandbox.py` docstring to note organizational vs security isolation
- [ ] Add to CLAUDE.md: "Scratch dirs in shared containers are organizationally isolated but not security-isolated"

## Work Log

- **2026-02-21**: Issue identified during security audit of commit 8f93d13
- Commit message acknowledged this: "Scratch dir isolation is organizational, not security — same UID, accepted trade-off for v1"

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename + default container + per-session scratch dirs

**Similar issues:**
- None - this is a new architectural limitation introduced by the default container model

**Security context:**
- Appropriate for single-user local deployment (current use case)
- Must be addressed before multi-user/hosted deployment
- Not a vulnerability in current threat model
