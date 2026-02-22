---
status: pending
priority: p2
issue_id: 62
tags: [code-review, quality, refactoring, sandbox]
created: 2026-02-21
---

# Container Creation Logic Duplication in ensure_default_container()

## Problem Statement

The `ensure_default_container()` method duplicates ~90 lines of Docker container creation logic from `_create_persistent_container()`. Both methods build nearly identical Docker run arguments, with only minor differences in labels, vault mounts, and `.claude` directory paths.

**Impact:** Medium-high maintenance burden - changes to container security flags, resource limits, or hardening must be made in two places.

**Introduced in:** Commit 8f93d13 (feat: trust level rename + default container)

## Findings

**Source:** Code Simplicity Reviewer (Confidence: 92)

**Duplicated sections:**

1. **Base Docker run args** (identical in both):
   ```python
   args = [
       "docker", "run", "-d",
       "--init",
       "--name", container_name,
       "--memory", CONTAINER_MEMORY_LIMIT,
       "--cpus", CONTAINER_CPU_LIMIT,
       "--cap-drop", "ALL",
       "--security-opt", "no-new-privileges",
       "--pids-limit", "100",
       "--tmpfs", "/scratch:size=512m,uid=1000,gid=1000",
   ]
   ```

2. **Network configuration** (identical):
   ```python
   if not config.network_enabled:
       args.extend(["--network", "none"])
   ```

3. **Capability mounts** (identical):
   ```python
   args.extend(self._build_capability_mounts(config))
   ```

4. **`.claude` directory setup** (nearly identical, just different paths):
   ```python
   claude_dir.mkdir(parents=True, exist_ok=True)
   claude_dir.chmod(0o700)
   args.extend(["-v", f"{claude_dir}:/home/sandbox/.claude:rw"])
   ```

5. **Container creation + error handling** (identical):
   ```python
   proc = await asyncio.create_subprocess_exec(*args, ...)
   _, stderr = await proc.communicate()
   if proc.returncode != 0:
       raise RuntimeError(f"Failed to create container: {stderr.decode()}")
   ```

**Only differences:**
- Labels: `{"app": "parachute", "workspace": slug}` vs `{"app": "parachute", "type": "default"}`
- Vault mount: `_build_mounts(config)` vs `f"{vault_path}:/vault:ro"`
- `.claude` path: `vault/.parachute/sandbox/{slug}/.claude` vs `vault/.parachute/sandbox/_default/.claude`

## Proposed Solutions

### Solution 1: Extract Shared _create_container() Method (Recommended)

**Approach:** Extract common container creation logic into a parameterized helper.

**Implementation:**
```python
async def _create_container(
    self,
    container_name: str,
    labels: dict[str, str],
    mounts: list[str],
    claude_dir: Path,
    config: AgentSandboxConfig,
) -> None:
    """Shared container creation logic for workspace and default containers."""
    args = [
        "docker", "run", "-d",
        "--init",
        "--name", container_name,
        "--memory", CONTAINER_MEMORY_LIMIT,
        "--cpus", CONTAINER_CPU_LIMIT,
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--pids-limit", "100",
        "--tmpfs", "/scratch:size=512m,uid=1000,gid=1000",
    ]

    # Add labels
    for key, value in labels.items():
        args.extend(["--label", f"{key}={value}"])

    # Network configuration
    if not config.network_enabled:
        args.extend(["--network", "none"])

    # Add volume mounts
    args.extend(mounts)

    # Setup .claude directory
    claude_dir.mkdir(parents=True, exist_ok=True)
    claude_dir.chmod(0o700)
    args.extend(["-v", f"{claude_dir}:/home/sandbox/.claude:rw"])

    args.extend([SANDBOX_IMAGE, "sleep", "infinity"])

    # Create container
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"Failed to create {container_name}: {stderr.decode()}")
    logger.info(f"Created container {container_name}")

async def _create_persistent_container(
    self, container_name: str, workspace_slug: str, config: AgentSandboxConfig
) -> None:
    """Create and start a persistent container for a workspace."""
    await self._create_container(
        container_name,
        labels={"app": "parachute", "workspace": workspace_slug},
        mounts=self._build_mounts(config),
        claude_dir=self.get_sandbox_claude_dir(workspace_slug),
        config=config,
    )

async def ensure_default_container(self, config: AgentSandboxConfig) -> str:
    # ... status checking ...
    if status is None:
        await self._create_container(
            DEFAULT_CONTAINER_NAME,
            labels={"app": "parachute", "type": "default"},
            mounts=["-v", f"{self.vault_path}:/vault:ro"] + self._build_capability_mounts(config),
            claude_dir=self.vault_path / SANDBOX_DATA_DIR / "_default" / ".claude",
            config=config,
        )
    return DEFAULT_CONTAINER_NAME
```

**Pros:**
- Eliminates ~60 lines of duplication
- Security flags only need updating in one place
- Easier to maintain consistent container hardening

**Cons:**
- Adds abstraction layer
- Labels and mounts become parameters instead of inline code

**Effort:** Small-Medium (1-2 hours)
**Risk:** Low

### Solution 2: Document Duplication, Keep Separate

**Approach:** Accept duplication as intentional, add comments explaining why.

**Pros:**
- No refactoring needed
- Each method self-contained

**Cons:**
- Security flag updates still need 2 locations
- Risk of divergence over time

**Effort:** Minimal (10 min)
**Risk:** Low

## Recommended Action

Implement **Solution 1** - the duplication is significant and includes security-critical flags (`--cap-drop`, `--security-opt`, `--tmpfs`) that should have a single source of truth.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/sandbox.py:688-732, 498-548`

**Components:**
- Docker container creation
- Sandbox lifecycle management

**Database changes:** None

## Acceptance Criteria

- [ ] Extract `_create_container()` helper method
- [ ] `_create_persistent_container()` delegates to helper
- [ ] `ensure_default_container()` delegates to helper
- [ ] All security flags preserved
- [ ] All existing tests pass
- [ ] Line count reduced by ~60 lines

## Work Log

- **2026-02-21**: Issue identified during code review of commit 8f93d13

## Resources

**Related issues:**
- #105 - run_persistent/run_default duplication (separate finding)

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename + default container
