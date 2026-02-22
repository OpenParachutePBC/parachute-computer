---
status: pending
priority: p3
issue_id: 62
tags: [code-review, quality, refactoring, sandbox]
created: 2026-02-21
---

# Repeated Docker Availability Checks Across run_* Methods

## Problem Statement

All three `run_*` methods (`run_agent`, `run_persistent`, `run_default`) duplicate the same Docker availability validation logic. The same 8-line check appears in all three places with identical error messages.

**Impact:** Low-medium - creates maintenance burden and inconsistent error messages if one location is updated but not others.

**Introduced in:** Commit 8f93d13 (added `run_default`, but pattern pre-existed)

## Findings

**Source:** Code Simplicity Reviewer (Confidence: 88)

**Duplicated code pattern:**
```python
if not await self.is_available():
    raise RuntimeError("Docker not available for sandboxed execution")

if not await self.image_exists():
    raise RuntimeError(
        f"Sandbox image '{SANDBOX_IMAGE}' not found. "
        "Build it from Settings > Capabilities."
    )
```

**Locations:**
- `run_agent()`: lines 375-383
- `run_persistent()`: lines 566-574
- `run_default()`: lines 744-751

## Proposed Solutions

### Solution 1: Extract _validate_docker_ready() Method (Recommended)

**Approach:** Single validation method called by all three `run_*` methods.

**Implementation:**
```python
async def _validate_docker_ready(self) -> None:
    """Ensure Docker is available and sandbox image exists."""
    if not await self.is_available():
        raise RuntimeError("Docker not available for sandboxed execution")

    if not await self.image_exists():
        raise RuntimeError(
            f"Sandbox image '{SANDBOX_IMAGE}' not found. "
            "Build it from Settings > Capabilities or run: "
            "docker build -t parachute-sandbox:latest computer/parachute/docker/"
        )

# In each run_* method:
async def run_agent(self, ...):
    await self._validate_docker_ready()
    # ... rest of method

async def run_persistent(self, ...):
    await self._validate_docker_ready()
    # ... rest of method

async def run_default(self, ...):
    await self._validate_docker_ready()
    # ... rest of method
```

**Pros:**
- Removes 16 lines of duplication
- Ensures consistent error messages
- Single location to improve error message (add build instructions, etc.)

**Cons:**
- Adds one method call indirection

**Effort:** Small (30 minutes)
**Risk:** Very low

### Solution 2: Keep Separate Checks

**Approach:** Accept duplication as self-documenting in each method.

**Pros:**
- Each method is self-contained
- No indirection

**Cons:**
- 3x maintenance burden for error message updates
- Risk of divergent error messages

**Effort:** None
**Risk:** None

## Recommended Action

Implement **Solution 1** - the duplication is small but creates unnecessary coupling. Extracting to a helper improves maintainability.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/sandbox.py:375-383, 566-574, 744-751`

**Components:**
- Docker validation
- Error messaging

**Database changes:** None

## Acceptance Criteria

- [ ] Extract `_validate_docker_ready()` method
- [ ] Update all three `run_*` methods to call helper
- [ ] All existing tests pass
- [ ] Error messages remain consistent

## Work Log

- **2026-02-21**: Issue identified during code review of commit 8f93d13

## Resources

**Related issues:**
- #105 - run_persistent/run_default duplication
- #106 - Container creation duplication
