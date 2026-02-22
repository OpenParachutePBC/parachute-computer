---
status: pending
priority: p3
issue_id: 62
tags: [code-review, documentation, sandbox, security]
created: 2026-02-21
---

# Missing Documentation for Network Isolation Behavior

## Problem Statement

The `--network none` Docker flag is used for sandboxed containers when `network_enabled=False`, but there's no user-facing documentation explaining:
1. What network isolation means for agent capabilities
2. How to configure it per workspace
3. What happens when MCP tools require network access
4. Performance implications of enabling network

**Impact:** Low-medium - Users might not understand why some tools fail or how to configure network access.

**Introduced in:** Pre-existing pattern, but default container (8f93d13) makes it more visible

## Findings

**Source:** Architecture Strategist (Confidence: 84)

**Current implementation:**
```python
# computer/parachute/core/sandbox.py:212, 511, 698
if not config.network_enabled:
    args.extend(["--network", "none"])
```

**What's documented:**
- Code shows network can be disabled
- `AgentSandboxConfig` has `network_enabled` field

**What's NOT documented:**
1. How does a user enable/disable network for a workspace?
2. What MCP tools break without network? (web search, API calls, git clone, etc.)
3. Does network isolation affect container-to-host communication?
4. Security rationale for default behavior

## Proposed Solutions

### Solution 1: Add User-Facing Documentation (Recommended)

**Approach:** Document network isolation in CLAUDE.md and add inline code comments.

**Implementation:**

**In `computer/CLAUDE.md`:**
```markdown
## Sandbox Network Isolation

By default, sandboxed agents run with network disabled (`--network none` in Docker).

### Network Behaviors:

| Setting | Container | Localhost | Internet | Use Case |
|---------|-----------|-----------|----------|----------|
| `network_enabled: false` (default) | ✅ IPC only | ❌ No | ❌ No | Maximum isolation |
| `network_enabled: true` | ✅ Full | ✅ Yes | ✅ Yes | Web APIs, git, downloads |

### Affected MCP Tools:

**Works WITHOUT network:**
- File operations (read, write, edit)
- Local code execution (bash, python, etc.)
- Memory/database queries
- Container-internal operations

**Requires network:**
- Web search
- API calls (OpenAI, GitHub, etc.)
- Git clone/pull from remote
- Package downloads (pip, npm, etc.)
- WebFetch tool

### Configuration:

Workspaces control network access via their config:
```json
{
  "slug": "my-workspace",
  "default_trust_level": "sandboxed",
  "network_enabled": true  // Enable network for this workspace
}
```

The default container uses `network_enabled` from server config.

### Security Note:

Network isolation is defense-in-depth. Even with network enabled, containers have:
- No access to host filesystem (except mounted vault)
- Limited CPU/memory/PIDs
- Dropped Linux capabilities
- `no-new-privileges` security option
```

**In code:**
```python
# computer/parachute/core/sandbox.py:510-513
# Network isolation: --network none prevents all external connections.
# This blocks internet access, DNS, and localhost BUT allows container IPC.
# Enable via config.network_enabled=True for tools requiring web access.
if not config.network_enabled:
    args.extend(["--network", "none"])
```

**Pros:**
- Comprehensive user-facing documentation
- Explains trade-offs clearly
- Shows how to configure per workspace
- Lists affected tools

**Cons:**
- None

**Effort:** Small (30 minutes)
**Risk:** None

### Solution 2: Add API Endpoint to Query Network Status

**Approach:** Add `/api/sandbox/capabilities` endpoint showing network status.

**Pros:**
- Programmatic access to sandbox capabilities
- Flutter UI can show network status

**Cons:**
- More complex than documentation
- Users still need documentation to understand implications

**Effort:** Medium (1-2 hours)
**Risk:** Low

## Recommended Action

Implement **Solution 1** - add documentation to CLAUDE.md and inline code comments. Users need to understand network isolation behavior before they can use the API effectively.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/CLAUDE.md` (new section)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/sandbox.py:212, 511, 698` (add comments)

**Components:**
- Docker sandbox networking
- Workspace configuration
- MCP tool capabilities

**Database changes:** None

**User impact:**
- Better understanding of when to enable network
- Clearer error messages when network-dependent tools fail
- Informed security decisions

## Acceptance Criteria

- [ ] Add "Sandbox Network Isolation" section to `computer/CLAUDE.md`
- [ ] Document network behaviors table (IPC/localhost/internet)
- [ ] List MCP tools that require network
- [ ] Show how to configure per workspace
- [ ] Add security note explaining defense-in-depth
- [ ] Add inline comment in sandbox.py explaining `--network none`

## Work Log

- **2026-02-21**: Issue identified during architecture review of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): default container (makes network isolation more prominent)

**Docker networking docs:**
- https://docs.docker.com/network/none/
- `--network none` creates container with only loopback interface
