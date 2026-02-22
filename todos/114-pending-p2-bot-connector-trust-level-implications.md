---
status: pending
priority: p2
issue_id: 62
tags: [code-review, agent-native, bots, security, documentation]
created: 2026-02-21
---

# Bot Connectors Should Document Trust Level Security Implications

## Problem Statement

Bot connectors (Telegram, Discord, Matrix) allow external users to interact with Parachute sessions via chat platforms. Each connector can be configured with a `default_trust_level`, but there's no documentation explaining:

1. **Security implications** of different trust levels for bot-initiated sessions
2. **Attack surface** when external users can trigger sandboxed vs direct execution
3. **Best practices** for multi-user vs single-user bot deployments
4. **Authorization model** - who can create sessions? who can access which workspaces?

**Impact:** Medium - Misconfigurations could allow untrusted bot users to execute code with higher privileges than intended, or conversely, over-restrict trusted users.

**Introduced in:** Pre-existing (bots existed before trust rename), but 8f93d13 makes trust levels more prominent

## Findings

**Source:** Agent-Native Reviewer (Confidence: 86)

**Current implementation:**
```python
# computer/parachute/connectors/telegram.py:45
# computer/parachute/connectors/discord.py:38
# computer/parachute/connectors/matrix.py:52
default_trust_level: TrustLevel = Field(
    default=TrustLevel.SANDBOXED,
    description="Default trust level for new sessions"
)
```

**What's missing:**

1. **No security guidance** on when to use direct vs sandboxed for bots
2. **No authorization documentation** - can any Telegram user create sessions?
3. **No multi-tenant considerations** - what if multiple users share a bot?
4. **No attack scenario examples** - what can a malicious bot user do?

## Proposed Solutions

### Solution 1: Add Security Section to Bot Connector Docs (Recommended)

**Approach:** Create comprehensive security documentation for bot deployments.

**Implementation:**

**New file: `computer/parachute/connectors/SECURITY.md`:**
```markdown
# Bot Connector Security Guide

## Trust Levels for Bot Sessions

Bot connectors create AI sessions on behalf of external users. Choose trust levels carefully:

### Trust Level Recommendations:

| Scenario | Recommended Trust | Rationale |
|----------|-------------------|-----------|
| **Public bot (Telegram/Discord)** | `sandboxed` (default) | Unknown users, network isolation |
| **Private bot (single user)** | `direct` or `sandboxed` | Depends on vault sensitivity |
| **Team bot (known users)** | `sandboxed` | Shared environment, defense-in-depth |
| **Development/testing** | `sandboxed` | Safe experimentation |

### Security Implications:

#### Sandboxed (default)
- ✅ Docker isolation - code runs in container
- ✅ No host filesystem access (except mounted vault)
- ✅ Network disabled by default
- ✅ Limited CPU/memory/PIDs
- ⚠️ MCP tools can still read/write vault files
- ⚠️ Agents can access workspace-specific directories

**Attack surface:**
- Malicious user can read/modify vault files via MCP tools
- Cannot escape container to host
- Cannot access other users' sessions (single-user deployment)

#### Direct (use with caution)
- ❌ Unrestricted code execution on host
- ❌ Full filesystem access
- ❌ Can modify server code, install packages, etc.
- ⚠️ Only use for trusted, authenticated users

**Attack surface:**
- Full compromise of Parachute server
- Access to all vault data
- Potential host system access

## Authorization Model

### Current Limitations:

Parachute is designed for **single-user local deployment**. Bot connectors currently:

- ❌ No per-user authentication
- ❌ No session isolation between bot users
- ❌ All bot users share the same vault
- ❌ No audit logging of who did what

### Deployment Recommendations:

**✅ SAFE: Single-user private bot**
- You control the bot token
- Only you have access (Telegram private chat, Discord DM)
- Trust level can be `direct` or `sandboxed` based on preference

**⚠️ RISKY: Public bot with sandboxed trust**
- Unknown users can create sessions
- All users can read/write your vault files
- Use only for non-sensitive vaults
- Consider this experimental/demo use case

**❌ UNSAFE: Public bot with direct trust**
- **NEVER** deploy a public bot with `default_trust_level: direct`
- Allows arbitrary code execution by strangers
- Complete compromise of your system

## Multi-User Considerations

Parachute does **NOT** currently support true multi-tenant deployments. If you need multi-user bot access:

1. **Use sandboxed trust** (required)
2. **Separate vault per user** (not yet implemented)
3. **Workspace-level access control** (not yet implemented)
4. **Session isolation** (not yet implemented)

For production multi-user deployments, wait for:
- Issue #XX - Per-user vault isolation
- Issue #YY - Workspace ACLs
- Issue #ZZ - Audit logging

## Best Practices

### 1. Start with sandboxed
Always default to `sandboxed` trust for bots. Only escalate to `direct` if you have a specific need and understand the risks.

### 2. Protect bot tokens
Bot tokens grant full control over sessions. Treat them like passwords:
- Never commit to git
- Use environment variables or secrets management
- Rotate tokens if compromised

### 3. Monitor bot activity
Check logs regularly for unexpected behavior:
```bash
parachute logs | grep "connector="
```

### 4. Limit bot capabilities
Disable network for sandboxed bots unless required:
```python
BotConnector(
    default_trust_level=TrustLevel.SANDBOXED,
    network_enabled=False  # Most restrictive
)
```

### 5. Use workspaces for sensitive data
Create workspace-specific sessions instead of workspace-less:
```python
# Bot creates session with workspace
session = await create_session(
    workspace_slug="personal",  # Restricted directory
    trust_level=TrustLevel.SANDBOXED
)
```

## Attack Scenarios

### Scenario 1: Malicious Public Bot User (sandboxed)

**Attacker goal:** Steal data from your vault

**What they can do:**
1. Send message to bot: "Show me all files in /vault"
2. Agent lists files via MCP tools
3. Attacker requests specific file contents
4. Agent reads and returns file via MCP

**Mitigation:**
- Don't deploy public bots with sensitive vaults
- Use workspace isolation (not yet implemented)
- Monitor bot activity logs

**Cannot do:**
- Escape container to host
- Access other users' sessions
- Modify server code
- Install host packages

### Scenario 2: Compromised Bot Token (direct trust)

**Attacker goal:** Full server compromise

**What they can do:**
1. Use stolen bot token to send messages
2. Agent executes arbitrary code on host
3. Install backdoors, steal credentials, pivot to other systems

**Mitigation:**
- **Never use direct trust for bots**
- Protect bot tokens
- Rotate tokens immediately if compromised
- Use sandboxed trust as defense-in-depth

## Future Enhancements

Planned improvements for safer multi-user bot deployments:

- [ ] Per-user vault isolation
- [ ] Workspace-level ACLs
- [ ] Session ownership and authorization
- [ ] Audit logging (who created which session)
- [ ] Rate limiting per bot user
- [ ] Token-based authentication for bot users
```

**In connector code:**
```python
# computer/parachute/connectors/base.py
class BotConnector(BaseModel):
    default_trust_level: TrustLevel = Field(
        default=TrustLevel.SANDBOXED,
        description=(
            "Default trust level for bot-initiated sessions. "
            "IMPORTANT: Use SANDBOXED for public bots. "
            "See computer/parachute/connectors/SECURITY.md for guidance."
        )
    )
```

**Pros:**
- Comprehensive security guidance
- Explicit attack scenarios
- Deployment recommendations
- Future roadmap transparency

**Cons:**
- Doesn't solve the underlying issues (single-user design)
- Requires users to read documentation

**Effort:** Medium (2-3 hours for comprehensive docs)
**Risk:** None (documentation only)

### Solution 2: Add Runtime Warnings for Risky Configurations

**Approach:** Log warnings when bots are configured with risky trust levels.

**Implementation:**
```python
# In connector startup
if self.default_trust_level == TrustLevel.DIRECT:
    logger.warning(
        f"{self.__class__.__name__} configured with DIRECT trust level. "
        "This allows arbitrary code execution by bot users. "
        "Only use for private, single-user bots. "
        "See computer/parachute/connectors/SECURITY.md"
    )
```

**Pros:**
- Alerts users to risky configurations
- Hard to miss (logs on startup)

**Cons:**
- Doesn't prevent misconfiguration
- Users might ignore warnings

**Effort:** Small (30 minutes)
**Risk:** Very low

## Recommended Action

Implement **both solutions**:
1. Create comprehensive SECURITY.md documentation (Solution 1)
2. Add runtime warnings for direct trust (Solution 2)

This provides both proactive guidance (docs) and reactive alerts (warnings).

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/connectors/SECURITY.md` (new)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/connectors/base.py` (add warning)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/connectors/telegram.py` (update docstring)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/connectors/discord.py` (update docstring)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/connectors/matrix.py` (update docstring)

**Components:**
- Bot connector security
- Trust level configuration
- Authorization model

**Database changes:** None

**Future work needed:**
- Per-user vault isolation (#TBD)
- Workspace ACLs (#TBD)
- Session authorization (#TBD)
- Audit logging (#TBD)

## Acceptance Criteria

- [ ] Create `computer/parachute/connectors/SECURITY.md` with comprehensive guidance
- [ ] Document trust level security implications
- [ ] Provide attack scenario examples
- [ ] Add deployment recommendations (safe/risky/unsafe)
- [ ] Explain current single-user limitations
- [ ] Add runtime warning for `default_trust_level: direct`
- [ ] Update connector docstrings to reference SECURITY.md

## Work Log

- **2026-02-21**: Issue identified during agent-native review of commit 8f93d13

## Resources

**Related issues:**
- Bot connectors exist but lack security documentation

**Security considerations:**
- Bots expose attack surface to external users
- Trust levels are primary security boundary
- Current design is single-user, not multi-tenant
