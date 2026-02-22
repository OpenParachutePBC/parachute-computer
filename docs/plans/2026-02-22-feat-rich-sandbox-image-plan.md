---
title: Rich Sandbox Image with Efficient Storage
type: feat
date: 2026-02-22
issue: 69
---

# Rich Sandbox Image with Efficient Storage

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
│  └─ Web automation: requests, beautifulsoup4, playwright
├─ /cache/pip (named volume, shared across all containers)
│  └─ Pip wheel cache + installed packages
├─ /cache/npm (named volume, shared across all containers)
│  └─ npm package cache
├─ /vault/{path} (bind mount, workspace working directory)
│  └─ User's files, scoped to workspace
└─ /home/sandbox/.claude (bind mount, per-workspace)
   └─ SDK transcripts and session state
```

### Container Pooling by Config Hash

**Hash inputs:**
```python
config_key = f"{trust_level}:{json.dumps(capabilities, sort_keys=True)}:{memory}:{cpu}:{timeout}"
config_hash = hashlib.sha256(config_key.encode()).hexdigest()[:8]
```

**Container naming:**
- Primary: `parachute-ws-{config_hash}`
- Collision fallback: `parachute-ws-{config_hash}-{workspace_slug[:8]}`

**Example:**
- Workspace A: trust=sandboxed, mem=512m, cpu=1.0, capabilities={mcps: all} → hash `abc123de`
- Workspace B: trust=sandboxed, mem=512m, cpu=1.0, capabilities={mcps: all} → hash `abc123de`
- **Result**: Both use container `parachute-ws-abc123de`

### Shared Package Cache Volumes

**Named Docker volumes:**
- `parachute-pip-cache`: Pip wheel cache and installed packages
- `parachute-npm-cache`: npm package cache

**Environment variables:**
```bash
PIP_CACHE_DIR=/cache/pip
npm_config_cache=/cache/npm
```

**Auto-install behavior:**
- Detect `pip install`, `npm install` commands in sandboxed Bash tool calls
- Auto-approve without user prompt
- Log: "Auto-approved: pip install pandas"
- Package downloads once, reused across all workspaces

---

## Technical Approach

### Phase 1: Rich Base Image

**Update Dockerfile.sandbox:**

```dockerfile
FROM python:3.13-slim

# System packages
RUN apt-get update && apt-get install -y \
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

# Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Claude Agent SDK
RUN pip install --no-cache-dir claude-agent-sdk

# Document/data processing libraries
RUN pip install --no-cache-dir \
    pandas \
    openpyxl \
    PyPDF2 \
    python-docx \
    reportlab

# Web automation libraries
RUN pip install --no-cache-dir \
    requests \
    beautifulsoup4 \
    playwright

# Install playwright browsers (headless chromium)
RUN playwright install chromium --with-deps

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash sandbox

USER sandbox
WORKDIR /home/sandbox

CMD ["sleep", "infinity"]
```

**Estimated image size**: ~1.2GB (vs. current 781MB)

**Breakdown:**
- Base + system tools: ~400MB
- Node.js 22: ~150MB
- Python packages: ~300MB
- Playwright + chromium: ~350MB

**Files to modify:**
- `computer/parachute/docker/Dockerfile.sandbox`

---

### Phase 2: Shared Package Cache Volumes

**Create named volumes on first use:**

```python
# computer/parachute/core/sandbox.py

def _ensure_cache_volumes(self) -> None:
    """Create shared package cache volumes if they don't exist."""
    volumes = ["parachute-pip-cache", "parachute-npm-cache"]

    for volume_name in volumes:
        result = subprocess.run(
            ["docker", "volume", "inspect", volume_name],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # Volume doesn't exist, create it
            subprocess.run(
                ["docker", "volume", "create", volume_name],
                check=True,
            )
            logger.info(f"Created shared cache volume: {volume_name}")
```

**Mount cache volumes in containers:**

```python
# computer/parachute/core/sandbox.py, in _run_persistent()

# After existing volume mounts
mounts.extend([
    "-v", "parachute-pip-cache:/cache/pip:rw",
    "-v", "parachute-npm-cache:/cache/npm:rw",
])

# Set environment variables
env_args.extend([
    "-e", "PIP_CACHE_DIR=/cache/pip",
    "-e", "npm_config_cache=/cache/npm",
])
```

**Files to modify:**
- `computer/parachute/core/sandbox.py`:
  - Add `_ensure_cache_volumes()` method
  - Call in `__init__()` or lazy-load on first container creation
  - Update `_run_persistent()` to mount cache volumes
  - Update `_run_default()` to mount cache volumes

---

### Phase 3: Container Pooling by Config Hash

#### 3.1 Config Hash Calculation

```python
# computer/parachute/models/workspace.py

import hashlib
import json
from typing import Optional

def calculate_sandbox_config_hash(
    trust_level: str,
    capabilities: dict,
    memory: str = "512m",
    cpu: str = "1.0",
    timeout: int = 300,
) -> str:
    """Calculate config hash for container pooling."""
    config_key = f"{trust_level}:{json.dumps(capabilities, sort_keys=True)}:{memory}:{cpu}:{timeout}"
    config_hash = hashlib.sha256(config_key.encode()).hexdigest()
    return config_hash[:8]  # First 8 chars
```

#### 3.2 Container Naming and Lookup

```python
# computer/parachute/core/sandbox.py

from parachute.models.workspace import calculate_sandbox_config_hash

# Replace per-slug locks with per-hash locks
self._hash_locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)

async def _ensure_container_for_workspace(
    self,
    workspace_slug: str,
    workspace_config: WorkspaceConfig,
) -> str:
    """Ensure container exists for workspace, using pooling if applicable."""

    # Calculate config hash
    capabilities = workspace_config.capabilities.model_dump() if workspace_config.capabilities else {}
    sandbox_config = workspace_config.sandbox or SandboxConfig()

    config_hash = calculate_sandbox_config_hash(
        trust_level="sandboxed",
        capabilities=capabilities,
        memory=sandbox_config.memory,
        cpu=sandbox_config.cpu,
        timeout=sandbox_config.timeout,
    )

    # Check if workspace opts out of pooling
    if sandbox_config.dedicated_container:
        container_name = f"parachute-ws-{workspace_slug}"
    else:
        container_name = f"parachute-ws-{config_hash}"

    # Acquire lock for this config (prevents race conditions)
    async with self._hash_locks[config_hash]:
        # Check if container exists
        result = subprocess.run(
            ["docker", "inspect", container_name],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            # Container exists, check state
            state = json.loads(result.stdout)[0]["State"]["Status"]

            if state == "running":
                return container_name
            elif state in ("exited", "created"):
                # Restart
                subprocess.run(["docker", "start", container_name], check=True)
                return container_name
            else:
                # Bad state, remove and recreate
                subprocess.run(["docker", "rm", "-f", container_name], check=True)

        # Create new container
        await self._create_persistent_container(
            container_name=container_name,
            workspace_config=workspace_config,
            config_hash=config_hash,
        )

        return container_name
```

#### 3.3 Update SandboxConfig Model

```python
# computer/parachute/models/workspace.py

class SandboxConfig(BaseModel):
    memory: str = Field(default="512m")
    cpu: str = Field(default="1.0")
    timeout: int = Field(default=300)
    dedicated_container: bool = Field(default=False)  # Opt-out of pooling
    container_id: Optional[str] = Field(default=None)  # Track assigned container
```

#### 3.4 Update Container Labels

```python
# computer/parachute/core/sandbox.py, in _create_persistent_container()

labels = {
    "app": "parachute",
    "config_hash": config_hash,
}

# If workspace-specific (not pooled), add workspace label
if workspace_slug:
    labels["workspace"] = workspace_slug

label_args = [f"--label={k}={v}" for k, v in labels.items()]
```

**Files to modify:**
- `computer/parachute/models/workspace.py`:
  - Add `calculate_sandbox_config_hash()` function
  - Update `SandboxConfig` model with new fields
- `computer/parachute/core/sandbox.py`:
  - Replace `_slug_locks` with `_hash_locks`
  - Add `_ensure_container_for_workspace()` method
  - Update `_create_persistent_container()` to accept config_hash and add labels
  - Update reconciliation to handle hash-based naming

---

### Phase 4: Auto-Install Permissions

**Detect package install commands:**

```python
# computer/parachute/core/permission_handler.py

import re

PACKAGE_INSTALL_PATTERNS = [
    re.compile(r'\bpip\s+install\b'),
    re.compile(r'\bpip3\s+install\b'),
    re.compile(r'\bnpm\s+install\b'),
    re.compile(r'\bnpm\s+i\b'),
]

def _is_package_install_command(self, command: str) -> bool:
    """Check if command is a package installation."""
    return any(pattern.search(command) for pattern in PACKAGE_INSTALL_PATTERNS)

async def check_bash_permission(
    self,
    command: str,
    working_directory: Optional[str] = None,
) -> bool:
    """Check if Bash command should be allowed."""

    # In sandboxed mode, auto-approve package installs
    if self.session.trust_level == "sandboxed":
        if self._is_package_install_command(command):
            logger.info(f"Auto-approved package install: {command[:100]}")
            return True

    # Otherwise, use normal permission flow
    return await self._request_bash_permission(command, working_directory)
```

**Files to modify:**
- `computer/parachute/core/permission_handler.py`:
  - Add `PACKAGE_INSTALL_PATTERNS`
  - Add `_is_package_install_command()` method
  - Update `check_bash_permission()` to auto-approve in sandboxed mode

**Note**: Current sandbox uses `permission_mode: "bypassPermissions"` (entrypoint.py:151), so permission handler isn't called inside sandbox. This auto-install logic is defensive - it will apply if permission mode changes in future.

---

### Phase 5: Cleanup & Monitoring

#### 5.1 Cache Size Monitoring

```python
# computer/parachute/core/sandbox.py

def get_cache_volume_sizes(self) -> dict[str, int]:
    """Get sizes of package cache volumes in bytes."""
    sizes = {}

    for volume_name in ["parachute-pip-cache", "parachute-npm-cache"]:
        # Run du inside a temporary container
        result = subprocess.run(
            [
                "docker", "run", "--rm",
                "-v", f"{volume_name}:/cache",
                "python:3.13-slim",
                "du", "-sb", "/cache",
            ],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            size_str = result.stdout.strip().split()[0]
            sizes[volume_name] = int(size_str)

    return sizes
```

#### 5.2 Cache Cleanup Command

```bash
# computer/parachute/cli/sandbox.py (new file)

import click
from parachute.core.sandbox import DockerSandbox

@click.group()
def sandbox():
    """Manage sandbox containers and caches."""
    pass

@sandbox.command()
@click.option("--dry-run", is_flag=True, help="Show what would be deleted")
def clean_cache(dry_run: bool):
    """Clean package cache volumes."""
    click.echo("Cleaning package caches...")

    for volume_name in ["parachute-pip-cache", "parachute-npm-cache"]:
        if dry_run:
            click.echo(f"Would clean: {volume_name}")
        else:
            # Remove and recreate volume
            subprocess.run(["docker", "volume", "rm", "-f", volume_name])
            subprocess.run(["docker", "volume", "create", volume_name])
            click.echo(f"Cleaned: {volume_name}")

@sandbox.command()
def inspect():
    """Show sandbox container and cache status."""
    sandbox = DockerSandbox(vault_path=Path.home() / "Parachute")

    # Cache sizes
    sizes = sandbox.get_cache_volume_sizes()
    click.echo("\nCache Volumes:")
    for name, size_bytes in sizes.items():
        size_mb = size_bytes / (1024 * 1024)
        click.echo(f"  {name}: {size_mb:.1f} MB")

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

    # Get all parachute containers
    result = subprocess.run(
        ["docker", "ps", "-a", "--filter", "label=app=parachute", "--format", "{{.Names}}\t{{.Labels}}"],
        capture_output=True,
        text=True,
    )

    containers = []
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        name, labels_str = line.split("\t")
        labels = dict(label.split("=", 1) for label in labels_str.split(",") if "=" in label)
        containers.append({"name": name, "labels": labels})

    # Load all workspace configs
    workspace_slugs = set()
    config_hashes = set()

    for config_file in (self.vault_path / ".parachute/workspaces").glob("*/config.yaml"):
        workspace = WorkspaceConfig.from_file(config_file)
        workspace_slugs.add(workspace.slug)

        # Calculate config hash
        if workspace.default_trust_level == "sandboxed":
            capabilities = workspace.capabilities.model_dump() if workspace.capabilities else {}
            sandbox_config = workspace.sandbox or SandboxConfig()
            config_hash = calculate_sandbox_config_hash(
                trust_level="sandboxed",
                capabilities=capabilities,
                memory=sandbox_config.memory,
                cpu=sandbox_config.cpu,
                timeout=sandbox_config.timeout,
            )
            config_hashes.add(config_hash)

    # Find orphans
    orphans = []
    for container in containers:
        name = container["name"]
        labels = container["labels"]

        # Check if workspace-specific container
        if "workspace" in labels:
            if labels["workspace"] not in workspace_slugs:
                orphans.append(name)

        # Check if pooled container
        elif "config_hash" in labels:
            if labels["config_hash"] not in config_hashes:
                orphans.append(name)

    # Remove orphans
    if orphans:
        logger.warning(f"Removing {len(orphans)} orphaned container(s)")
        for name in orphans:
            subprocess.run(["docker", "rm", "-f", name])

    logger.info(f"Reconciled {len(containers) - len(orphans)} active container(s)")
```

**Files to modify:**
- `computer/parachute/core/sandbox.py`:
  - Add `get_cache_volume_sizes()` method
  - Update `reconcile_containers()` to remove orphans
- `computer/parachute/cli/sandbox.py` (new):
  - Add `clean-cache` command
  - Add `inspect` command
- `computer/parachute/cli/__init__.py`:
  - Register sandbox command group

---

## Acceptance Criteria

### Functional Requirements

- [ ] Base image includes git, build-essential, jq, tree
- [ ] Base image includes pandas, openpyxl, PyPDF2, python-docx, reportlab
- [ ] Base image includes requests, beautifulsoup4, playwright
- [ ] Shared cache volumes created on first use
- [ ] pip installs use `/cache/pip`, npm installs use `/cache/npm`
- [ ] Packages installed once are reused across all workspaces
- [ ] Two workspaces with identical configs share one container
- [ ] Each workspace gets isolated SDK transcripts despite shared container
- [ ] `pip install` commands auto-approved in sandboxed mode
- [ ] `npm install` commands auto-approved in sandboxed mode
- [ ] Orphaned containers removed on server startup
- [ ] `parachute sandbox inspect` shows cache sizes and container count
- [ ] `parachute sandbox clean-cache` removes and recreates cache volumes

### Non-Functional Requirements

- [ ] Image build completes in < 5 minutes
- [ ] Image size < 1.5GB
- [ ] Cache volume size monitored, warning at 5GB
- [ ] Container pooling reduces memory usage by 50%+ for identical workspaces
- [ ] No session isolation regressions (verified by tests)

### Quality Gates

- [ ] Unit tests pass for config hash calculation
- [ ] Integration test: two workspaces share container, separate transcripts
- [ ] Integration test: workspace opts out of pooling gets dedicated container
- [ ] Integration test: orphan container removed on reconciliation
- [ ] Documentation updated: what's pre-installed, how pooling works, cache cleanup

---

## Migration Strategy

### Backward Compatibility

**Existing containers continue to work:**
- Old naming: `parachute-ws-{workspace_slug}`
- New naming: `parachute-ws-{config_hash}`
- Reconciliation handles both schemes

**Workspace configs without new fields:**
- `dedicated_container` defaults to `False` (opt-in to pooling)
- `container_id` defaults to `None` (auto-assigned)

**Upgrade path:**
1. Server update deploys new code
2. Reconciliation runs on startup
3. Existing containers labeled as workspace-specific (not pooled)
4. New workspaces use pooling by default
5. Old containers phased out as workspaces deleted or recreated

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
5. New pooled containers ignored (orphan cleanup disabled)

---

## Testing Strategy

### Unit Tests

```python
# tests/unit/test_sandbox_pooling.py

def test_calculate_sandbox_config_hash():
    """Test config hash calculation."""
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

    assert hash1 == hash2  # Order-independent

def test_config_hash_changes_on_param_change():
    """Test config hash changes when params differ."""
    hash1 = calculate_sandbox_config_hash("sandboxed", {}, "512m", "1.0", 300)
    hash2 = calculate_sandbox_config_hash("sandboxed", {}, "1g", "1.0", 300)  # Different memory

    assert hash1 != hash2
```

### Integration Tests

```python
# tests/integration/test_container_pooling.py

@pytest.mark.asyncio
async def test_two_workspaces_share_container():
    """Test that two workspaces with identical configs share a container."""

    # Create workspace A
    workspace_a = await create_workspace(
        slug="test-a",
        default_trust_level="sandboxed",
        sandbox=SandboxConfig(memory="512m", cpu="1.0"),
    )

    # Create workspace B (identical config)
    workspace_b = await create_workspace(
        slug="test-b",
        default_trust_level="sandboxed",
        sandbox=SandboxConfig(memory="512m", cpu="1.0"),
    )

    # Start sessions in both workspaces
    session_a = await orchestrator.send_message(workspace=workspace_a, message="hello")
    session_b = await orchestrator.send_message(workspace=workspace_b, message="hello")

    # Check container names
    container_a = await sandbox.get_container_for_workspace(workspace_a.slug)
    container_b = await sandbox.get_container_for_workspace(workspace_b.slug)

    assert container_a == container_b  # Same container

    # Verify separate transcripts
    transcript_a = await get_session_transcript(session_a.id)
    transcript_b = await get_session_transcript(session_b.id)

    assert transcript_a != transcript_b  # Different transcripts

@pytest.mark.asyncio
async def test_dedicated_container_opt_out():
    """Test that workspace with dedicated_container=True gets own container."""

    workspace = await create_workspace(
        slug="test-dedicated",
        default_trust_level="sandboxed",
        sandbox=SandboxConfig(dedicated_container=True),
    )

    container_name = await sandbox.get_container_for_workspace(workspace.slug)

    assert container_name == f"parachute-ws-{workspace.slug}"  # Not pooled
```

### Manual Testing

**Test scenarios:**
1. **Pre-installed tools work:**
   - Create sandboxed session
   - Run: `git --version` → should work without install
   - Run: `python -c "import pandas; print(pandas.__version__)"` → should work

2. **Package cache reused:**
   - Workspace A: `pip install numpy`
   - Workspace B: `pip install numpy` → should be faster (cached)

3. **Container pooling works:**
   - Create 5 workspaces with identical configs
   - Check `docker ps` → should see 1 container, not 5

4. **Session isolation maintained:**
   - Workspace A: create file in `/scratch/test.txt`
   - Workspace B: list `/scratch/` → shouldn't see `test.txt`

---

## Implementation Files

### New Files

```
computer/parachute/cli/sandbox.py          # CLI commands for cache management
tests/unit/test_sandbox_pooling.py         # Config hash unit tests
tests/integration/test_container_pooling.py # Integration tests
```

### Modified Files

```
computer/parachute/docker/Dockerfile.sandbox
├─ Add development tools (git, build-essential, jq)
├─ Add document/data libraries (pandas, PyPDF2, etc.)
└─ Add web automation libraries (requests, playwright)

computer/parachute/core/sandbox.py
├─ Add _ensure_cache_volumes() method
├─ Add _ensure_container_for_workspace() method
├─ Update _run_persistent() to mount cache volumes
├─ Replace _slug_locks with _hash_locks
├─ Update reconcile_containers() to remove orphans
└─ Add get_cache_volume_sizes() method

computer/parachute/models/workspace.py
├─ Add calculate_sandbox_config_hash() function
└─ Update SandboxConfig with dedicated_container, container_id fields

computer/parachute/core/permission_handler.py
├─ Add PACKAGE_INSTALL_PATTERNS
├─ Add _is_package_install_command() method
└─ Update check_bash_permission() to auto-approve in sandboxed mode

computer/parachute/cli/__init__.py
└─ Register sandbox command group
```

---

## Dependencies & Risks

### Dependencies

**Docker:**
- Requires Docker daemon running
- Requires Docker API v1.41+ (for label filters)
- macOS: Docker Desktop or Colima

**Disk space:**
- Base image: ~1.2GB (vs. current 781MB) = +419MB
- Cache volumes: Up to 5GB (monitored, cleaned as needed)
- Per-workspace: SDK transcripts (~1-10MB each)

**Build tools:**
- gcc, make, libpython3-dev for native extensions
- playwright browsers (~350MB)

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|-----------|
| **Image build timeout on slow networks** | Medium | High | Multi-stage build, cache layers, retry logic |
| **Cache volume grows unbounded** | High | Medium | Monitoring, cleanup command, size warnings |
| **Config hash collision** | Low | High | Use full 64-char hash internally, truncate only for display |
| **Workspace-to-pool race conditions** | Medium | High | Asyncio locks per config hash, test concurrent creation |
| **macOS Docker VM disk exhaustion** | Medium | Medium | Document cache cleanup, add disk monitoring |
| **Playwright browser download fails** | Medium | Low | Fallback: skip browser install, document manual install |

---

## Future Enhancements

**Beyond initial implementation:**

1. **Workspace image customization**
   - Allow Dockerfile per workspace: `vault/.parachute/workspaces/{slug}/Dockerfile`
   - Build custom images: `parachute workspace build {slug}`
   - Use case: ML workflows with CUDA, specific Python versions

2. **Image variants**
   - Minimal: Current size (~781MB), no pre-installed tools
   - Standard: New size (~1.2GB), common tools (default)
   - Full: ~2GB, includes ML libraries (torch, tensorflow)

3. **Advanced cache strategies**
   - Per-workspace virtual environments (avoid version conflicts)
   - Lockfiles: `requirements.txt`, `package-lock.json` auto-detected
   - Cache warming: Pre-download top 100 PyPI packages

4. **Container health monitoring**
   - Detect hung processes (stuck >10min)
   - Auto-restart unhealthy containers
   - Metrics: memory usage, CPU, process count

5. **Desktop Extension equivalents**
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
- Asyncio locks for concurrency: `sandbox.py:474`
- OOM detection and cleanup: `sandbox.py:667-677`
- Volume mounting strategy: `sandbox.py:121-187`
- Container reconciliation: `sandbox.py:834-871`

### External References

**Brainstorm:**
- Issue #69: "Rich Sandbox Image with Efficient Storage"
- Brainstorm file: `docs/brainstorms/2026-02-18-rich-sandbox-image-brainstorm.md`

**Docker:**
- Named volumes: https://docs.docker.com/storage/volumes/
- Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Container labels: https://docs.docker.com/config/labels-custom-metadata/

**Python packaging:**
- pip cache: https://pip.pypa.io/en/stable/topics/caching/
- pip environment variables: https://pip.pypa.io/en/stable/topics/configuration/

**npm:**
- npm cache: https://docs.npmjs.com/cli/v10/commands/npm-cache
- npm config: https://docs.npmjs.com/cli/v10/using-npm/config

---

## Success Metrics

**User experience:**
- Zero "ModuleNotFoundError" for common tasks (pandas, requests, PyPDF2)
- Package installs happen transparently (no permission prompts)
- Non-developers don't need to understand dependencies

**Efficiency:**
- 10 workspaces with identical configs → 1 container (10x reduction)
- Shared package cache reduces redundant downloads by 80%+
- Image build time < 5 minutes

**Developer experience:**
- Clear documentation: what's pre-installed, how pooling works
- `parachute sandbox inspect` shows resource usage
- `parachute sandbox clean-cache` reclaims space easily
