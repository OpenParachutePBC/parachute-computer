---
status: pending
priority: p2
issue_id: 62
tags: [code-review, quality, refactoring, sandbox]
created: 2026-02-21
---

# Massive Code Duplication: run_persistent() and run_default() Methods

## Problem Statement

The new `run_default()` and existing `run_persistent()` methods in `DockerSandbox` share 95% identical logic (~160 lines of duplicated code). Both methods build identical Docker exec arguments, construct stdin payloads the same way, handle OOM errors identically, and use the same subprocess streaming pattern.

**Impact:** High maintenance burden - any changes to exec logic, error handling, or capability construction must be made in two places, risking drift and bugs.

**Introduced in:** Commit 8f93d13 (feat: trust level rename + default container)

## Findings

**Source:** Code Simplicity Reviewer (Confidence: 95)

**Duplicated sections:**

1. **Docker exec args construction** (lines 755-770 vs 579-595):
   - Identical env var setup for `PARACHUTE_SESSION_ID`, `PARACHUTE_AGENT_TYPE`, `PARACHUTE_CWD`, `PARACHUTE_MODEL`, `PARACHUTE_MCP_SERVERS`
   - Both methods build the same 17-line list

2. **Stdin payload construction** (lines 781-795 vs 605-627):
   - Identical logic for `claude_token`, `system_prompt`, `resume_session_id`
   - Same capabilities dict construction (only difference: workspace version includes plugin_dirs)

3. **OOM error handling** (lines 800-815 vs 632-650):
   - Near-identical exit code 137 handling
   - Same container removal + error message pattern
   - Only difference: container name in log message

4. **Subprocess streaming** (both call `_stream_process()` with same pattern)

**Why duplication exists:**
The methods differ only in:
- Container source: `ensure_container(workspace_slug)` vs `ensure_default_container()`
- Label: `"persistent sandbox"` vs `"default sandbox"`
- Plugin dirs: included in workspace, excluded in default

## Proposed Solutions

### Solution 1: Extract Common Implementation (Recommended)

**Approach:** Extract shared logic into `_run_in_persistent_container()` helper method.

**Implementation:**
```python
async def _run_in_persistent_container(
    self,
    container_name: str,
    config: AgentSandboxConfig,
    message: str,
    resume_session_id: str | None,
    include_plugin_dirs: bool,
    label: str,
) -> AsyncGenerator[dict, None]:
    """Shared implementation for run_persistent and run_default."""
    await self._validate_docker_ready()

    exec_args = self._build_exec_args(container_name, config)

    proc = await asyncio.create_subprocess_exec(
        *exec_args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        stdin_payload = self._build_stdin_payload(
            message, config, resume_session_id, include_plugin_dirs
        )

        async for event in self._stream_process(proc, stdin_payload, config, label):
            if event.get("type") == "exit_error":
                returncode = event["returncode"]
                if returncode == 137:
                    await self._handle_container_oom(container_name)
                    yield {"type": "error", "error": "Container OOM"}
                else:
                    yield {"type": "error", "error": f"Sandbox error (exit {returncode})"}
            else:
                yield event
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()

async def run_persistent(...):
    container_name = await self.ensure_container(workspace_slug, config)
    async for event in self._run_in_persistent_container(
        container_name, config, message, resume_session_id,
        include_plugin_dirs=True, label="persistent sandbox"
    ):
        yield event

async def run_default(...):
    container_name = await self.ensure_default_container(config)
    async for event in self._run_in_persistent_container(
        container_name, config, message, resume_session_id,
        include_plugin_dirs=False, label="default sandbox"
    ):
        yield event
```

**Pros:**
- Eliminates ~140 lines of duplication
- Single source of truth for exec logic
- Future changes only need to touch one method

**Cons:**
- Adds one level of indirection
- Slightly more complex call signature

**Effort:** Medium (2-3 hours)
**Risk:** Low (extract method refactoring with tests)

### Solution 2: Keep Separate, Add Maintenance Tests

**Approach:** Accept duplication but add tests that verify both methods stay in sync.

**Pros:**
- No refactoring needed
- Each method remains self-contained

**Cons:**
- Duplication persists
- Tests are brittle (break on intentional divergence)
- Higher maintenance burden

**Effort:** Small (30 min)
**Risk:** Low

## Recommended Action

Implement **Solution 1** - the code duplication is significant enough to warrant extraction. The shared helper method provides clear value and the refactoring is low-risk.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/sandbox.py:550-829`

**Additional helper methods to extract:**
- `_build_exec_args()` - Docker exec argument construction
- `_build_stdin_payload()` - Capabilities + message serialization
- `_handle_container_oom()` - OOM error recovery

**Components:**
- Docker sandbox execution
- Container lifecycle management

**Database changes:** None

## Acceptance Criteria

- [ ] Extract `_run_in_persistent_container()` with shared logic
- [ ] Extract `_build_exec_args()` helper
- [ ] Extract `_build_stdin_payload()` helper
- [ ] Extract `_handle_container_oom()` helper
- [ ] `run_persistent()` delegates to shared method
- [ ] `run_default()` delegates to shared method
- [ ] All existing tests pass
- [ ] Line count reduced by ~120 lines

## Work Log

- **2026-02-21**: Issue identified during code review of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename + default container + per-session scratch dirs

**Similar patterns:**
- `_create_persistent_container()` and `ensure_default_container()` also have significant duplication (separate todo)
