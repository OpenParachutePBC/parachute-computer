# Rich Sandbox Image with Efficient Storage

**Date:** 2026-02-18
**Status:** Brainstorm
**Component:** computer (sandbox)
**Priority:** P2

---

## What We're Building

A batteries-included sandbox Docker image that provides Claude Desktop/Cowork-level convenience for non-developers, while using layered volumes and container pooling to minimize storage duplication across multiple workspaces.

**Core goals:**
1. **Convenience** - Pre-install common tools (document/data handling, dev tools, web automation) so users don't hit missing dependency errors
2. **Efficiency** - Share base layers and package caches across workspaces to minimize disk usage
3. **Auto-install** - Allow runtime package installation (`pip install`, `npm install`) with shared caching
4. **Container pooling** - Workspaces with identical configs share containers

**Inspiration:** Claude Desktop and Cowork provide accessible AI experiences for non-developers through:
- Pre-installed tools and runtimes (Node.js, Python environments)
- Document generation capabilities (Excel with formulas, PowerPoint, PDF)
- Zero-config dependency management (bundled in Desktop Extensions)
- No terminal knowledge required

Parachute's sandbox should provide similar convenience while maintaining the flexibility and efficiency needed for diverse workspace configurations.

---

## Why This Approach

### Current State

Parachute has a working sandbox implementation:
- Binary trust model (trusted/untrusted)
- Ephemeral containers for one-off sessions
- Persistent containers for workspace sessions (`parachute-ws-{workspace_slug}`)
- Base image: Python 3.13-slim + Node.js 22 + Claude Code CLI
- Per-workspace SDK transcript storage in `vault/.parachute/sandbox/{slug}/.claude/`

**Current limitations:**
- Minimal base image (~500MB) - only Python, Node, Claude SDK
- Each workspace gets its own container (no sharing)
- No package caching - repeated `pip install` across workspaces
- Runtime dependency errors for common tasks (PDF handling, data processing, web scraping)

### Selected Approach: Layered Volumes with Package Cache

**Architecture:**
```
Container: parachute-ws-{config_hash}
├─ Base Image (read-only)
│  └─ Pre-installed common tools
├─ /cache/pip (shared volume, read-write)
│  └─ Packages installed at runtime, shared across all containers
├─ /cache/npm (shared volume, read-write)
│  └─ Packages installed at runtime, shared across all containers
├─ /vault/{path} (workspace working dir, read-write)
│  └─ User's working directory, scoped to workspace
└─ /home/sandbox/.claude (workspace overlay, read-write)
   └─ SDK transcripts, per-workspace state
```

**How it works:**

1. **Rich base image** contains pre-installed tools for common workflows:
   - **Document/data:** pandas, openpyxl, PyPDF2, python-docx, reportlab
   - **Development:** git, common build tools, linters
   - **Web automation:** requests, beautifulsoup4, playwright

2. **Container pooling by config hash:**
   - Hash includes: `trust_level + capabilities + memory + cpu + timeout`
   - Multiple workspaces with identical configs share the same container
   - Container naming: `parachute-ws-{first_8_chars_of_hash}`
   - Sessions isolated via `docker exec` with separate SDK transcript paths

3. **Shared package cache volumes:**
   - Named volumes: `parachute-pip-cache`, `parachute-npm-cache`
   - Mounted in all containers at `/cache/pip`, `/cache/npm`
   - Auto-install enabled: `pip install`, `npm install` auto-approved in sandbox
   - Packages installed once, reused across all workspaces

4. **Per-workspace overlay volumes:**
   - SDK transcripts: `vault/.parachute/sandbox/{slug}/.claude/` mounted at `/home/sandbox/.claude`
   - Working directory: `vault/{path}` mounted at `/vault/{path}`
   - Workspace state isolated, container shared

**Why this beats alternatives:**

**vs. Fat Base Image (every package pre-installed):**
- Lower download/build time (don't pre-install everything)
- Can adapt to new packages without rebuilding base image
- Still provides core tooling out of the box

**vs. Workspace Image Templates (multiple base images for different use cases):**
- Simpler - one base image to maintain
- No user decision required ("which template do I need?")
- More flexible - works for hybrid workflows

**vs. One container per workspace (current):**
- Dramatically lower resource usage with many workspaces
- Still maintains isolation at SDK transcript level
- Enables efficient scaling

---

## Key Decisions

### 1. Pre-Installed Tool Selection

**Document/Data Processing:**
- `pandas` - CSV, Excel data manipulation
- `openpyxl` - Excel read/write with formulas
- `PyPDF2` - PDF creation/manipulation
- `python-docx` - Word document generation
- `reportlab` - PDF generation from scratch
- `csv` - Built-in CSV handling

**Development Tools:**
- `git` - Version control
- `jq` - JSON processing
- `yq` - YAML processing
- Build essentials (gcc, make for native extensions)

**Web Automation:**
- `requests` - HTTP client
- `beautifulsoup4` - HTML parsing
- `playwright` - Browser automation
- `selenium` - Alternative browser automation

**Rationale:** These cover 80% of common non-developer workflows (data analysis, document generation, web research) while keeping base image manageable (~800MB-1GB vs ~500MB current).

### 2. Config Hash for Container Pooling

**Hash inputs:**
```python
config_key = f"{trust_level}:{capabilities_json}:{memory}:{cpu}:{timeout}"
config_hash = hashlib.sha256(config_key.encode()).hexdigest()[:8]
```

**Container naming:**
- Primary: `parachute-ws-{config_hash}`
- Collision fallback: `parachute-ws-{config_hash}-{workspace_slug}`

**Workspace-to-container mapping:**
- Stored in workspace config: `sandbox.container_id` (optional field)
- Reconciliation on startup: match existing containers to workspace configs
- Cleanup: containers without matching workspaces are orphans (log warning, manual cleanup)

### 3. Package Cache Volume Management

**Volume creation:**
- Created on first use via Docker volume mount
- Persists across container recreations
- Shared read-write across all sandbox containers

**Cache structure:**
```
/cache/pip/
├─ wheels/          # Pip wheel cache
└─ packages/        # Installed packages

/cache/npm/
└─ _cacache/        # npm cache directory
```

**Environment variables:**
```bash
PIP_CACHE_DIR=/cache/pip/wheels
npm_config_cache=/cache/npm
```

**Cleanup strategy (future):**
- Periodic LRU eviction (e.g., monthly cron job)
- Size limit monitoring (warn if cache > 5GB)
- Manual cleanup command: `parachute sandbox clean-cache`

### 4. Auto-Install Permission

**Sandbox permission handler changes:**
- Detect `pip install`, `npm install`, `pip3 install`, `npm i` commands in Bash tool calls
- Auto-approve without user prompt (untrusted mode only)
- Log installations for transparency: "Auto-approved: pip install pandas"

**Security:**
- Only applies in untrusted (sandboxed) mode
- Packages install in isolated container, can't affect host
- User can still review commands via chat history

**User experience:**
- Non-developer: "analyze this CSV" → pandas auto-installs if needed → works immediately
- Developer: "install pytest" → happens transparently → tests run

### 5. Session Isolation in Shared Containers

**Current per-workspace isolation:**
- SDK transcripts: Different `.claude/` mount paths per workspace
- Working directory: Different `/vault/{path}` mounts per workspace
- Sessions delivered via: `docker exec -i parachute-ws-{hash} ...`

**No changes needed:**
- Sharing containers doesn't break session isolation
- Each `docker exec` is a separate process tree
- SDK transcript paths already workspace-scoped

**Validation:**
- Existing test coverage in `test_trust_levels.py` confirms isolation
- Add test: "two workspaces, same config, verify separate transcripts"

---

## Implementation Phases

### Phase 1: Rich Base Image
**Scope:** Expand base image with pre-installed tools
**Deliverables:**
- Updated `Dockerfile.sandbox` with document/data/web tools
- Build script updates for new dependencies
- Verification: `docker run parachute-sandbox:latest pip list`

### Phase 2: Shared Package Cache
**Scope:** Add shared pip/npm cache volumes
**Deliverables:**
- Volume mounts in `sandbox.py` (`-v parachute-pip-cache:/cache/pip`)
- Environment variables in `entrypoint.py`
- Cache cleanup command in CLI

### Phase 3: Container Pooling
**Scope:** Hash-based container naming and reuse
**Deliverables:**
- Config hash function in `workspace.py`
- Container lookup/reuse logic in `sandbox.py`
- Reconciliation updates for hash-based naming
- Workspace config field: `sandbox.container_id`

### Phase 4: Auto-Install Permissions
**Scope:** Auto-approve package installs in sandbox
**Deliverables:**
- Command detection in `permission_handler.py`
- Auto-approval for `pip install`, `npm install`
- Installation logging

### Phase 5: Cleanup & Monitoring
**Scope:** Cache management and orphan container cleanup
**Deliverables:**
- `parachute sandbox clean-cache` command
- Orphan container detection in reconciliation
- Cache size monitoring

---

## Open Questions

1. **Should we provide a "minimal" base image option?**
   - Use case: Users who want faster builds and don't need pre-installed tools
   - Tradeoff: More complexity (multiple images) vs. user choice
   - Lean toward: Single rich image to start, add minimal variant if users request it

2. **How do we handle package version conflicts?**
   - Scenario: Workspace A needs pandas 1.x, Workspace B needs pandas 2.x
   - Current answer: Shared cache, last install wins (not ideal)
   - Options:
     - Accept limitation (document it)
     - Use virtual environments per workspace (adds complexity)
     - Fall back to per-workspace containers on conflict detection
   - Lean toward: Document limitation, add venv support in Phase 3 if needed

3. **Should container pooling be opt-in or opt-out?**
   - Opt-in: Safer, users choose efficiency
   - Opt-out: More efficient by default, users choose isolation
   - Lean toward: Opt-out (default to pooling, allow `sandbox.dedicated_container: true`)

4. **How do we communicate base image updates to users?**
   - When adding new pre-installed tools, existing containers won't have them
   - Options:
     - Force rebuild on server update (disruptive)
     - Versioned images with automatic migration
     - Manual rebuild command: `parachute sandbox rebuild`
   - Lean toward: Versioned images + automatic migration on server update

5. **What's the upgrade path from current per-workspace containers?**
   - Existing deployments have `parachute-ws-{workspace_slug}` containers
   - Migration strategy:
     - Keep old containers until workspaces are deleted
     - New containers use hash-based naming
     - Reconciliation handles both naming schemes
   - Need: Migration guide in CHANGELOG

---

## Success Criteria

**User Experience:**
- Non-developer can say "analyze this Excel file" and it works without dependency errors
- Developers don't hit missing tool errors for common tasks
- Package installs happen transparently without permission prompts

**Efficiency:**
- 10 workspaces with identical configs use 1 container (vs. 10 currently)
- Shared package cache reduces redundant downloads
- Base image download is one-time cost, reused across all workspaces

**Developer Experience:**
- Clear documentation: what's pre-installed, what's cached, how pooling works
- Easy debugging: `parachute sandbox inspect` shows container mapping
- Simple cleanup: `parachute sandbox clean-cache` reclaims space

---

## Future Enhancements

**Beyond initial implementation:**

1. **Workspace image customization**
   - Allow workspace-specific Dockerfile for specialized environments
   - Build custom images on demand: `parachute workspace build {slug}`
   - Use case: ML workflows with specific CUDA versions

2. **Container health monitoring**
   - Detect hung processes in persistent containers
   - Auto-restart unhealthy containers
   - Metrics: memory usage, process count, uptime

3. **Advanced cache strategies**
   - Per-workspace virtual environments (avoid version conflicts)
   - Dependency lockfiles (reproducible builds)
   - Cache warming (pre-download popular packages)

4. **Desktop Extension equivalents**
   - Bundle MCP servers with dependencies into workspace templates
   - One-click workspace creation from templates
   - Gallery of pre-configured workspaces (data science, web dev, research)

---

## Related Context

**Existing brainstorms:**
- Issue #62: "Workspace & Chat Organization Rethink" - discusses workspace/volume relationship
- This brainstorm answers the "how do volumes work?" question from #62

**Current architecture:**
- `computer/parachute/core/sandbox.py` - Docker sandbox implementation
- `computer/parachute/models/workspace.py` - Workspace config models
- `computer/parachute/docker/Dockerfile.sandbox` - Current minimal base image

**Inspiration sources:**
- Claude Desktop: Desktop Extensions (.mcpb bundles) with bundled dependencies
- Cowork: Pre-configured plugins for domain-specific workflows
- Goal: Bring that convenience to Parachute's sandbox environment
