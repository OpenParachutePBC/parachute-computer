# Bot Connector Security Guide

> **IMPORTANT**: Parachute is designed for **single-user local deployment**. Bot connectors expose your Parachute instance to external users. Read this guide carefully before deploying bots.

---

## Trust Levels for Bot Sessions

Bot connectors create AI sessions on behalf of external users (Telegram, Discord, Matrix). Choose trust levels carefully:

### Trust Level Recommendations

| Scenario | Recommended Trust | Rationale |
|----------|-------------------|-----------|
| **Public bot (Telegram/Discord)** | `sandboxed` (default) | Unknown users, network isolation |
| **Private bot (single user)** | `direct` or `sandboxed` | Depends on vault sensitivity |
| **Team bot (known users)** | `sandboxed` | Shared environment, defense-in-depth |
| **Development/testing** | `sandboxed` | Safe experimentation |

### Security Implications

#### Sandboxed (default) ✅

**What it provides:**
- ✅ Docker isolation - code runs in container
- ✅ No host filesystem access (except mounted vault)
- ✅ Network disabled by default
- ✅ Limited CPU/memory/PIDs
- ✅ Dropped Linux capabilities
- ✅ `no-new-privileges` security option

**What it CANNOT prevent:**
- ⚠️ MCP tools can still read/write vault files
- ⚠️ Agents can access workspace-specific directories
- ⚠️ No per-user isolation (all bot users share same vault)

**Attack surface:**
- Malicious user can read/modify vault files via MCP tools
- Cannot escape container to host
- Cannot access other users' sessions (single-user deployment)
- Cannot modify server code or install host packages

#### Direct (use with EXTREME caution) ⚠️

**What it allows:**
- ❌ Unrestricted code execution on host
- ❌ Full filesystem access
- ❌ Can modify server code, install packages, etc.
- ❌ Full system compromise

**Attack surface:**
- Complete compromise of Parachute server
- Access to all vault data
- Potential host system access
- **NEVER use for public bots**

---

## Authorization Model

### Current Limitations

Parachute bot connectors currently have **NO**:

- ❌ Per-user authentication
- ❌ Session isolation between bot users
- ❌ User-specific vault access control
- ❌ Audit logging of who did what
- ❌ Rate limiting per user
- ❌ Permission scopes or ACLs

**All bot users share the same vault and have identical access.**

### Deployment Recommendations

#### ✅ SAFE: Single-user private bot

**Scenario:** You run a Telegram bot for personal use only.

- You control the bot token
- Only you have access (Telegram private chat, Discord DM)
- Trust level can be `direct` or `sandboxed` based on your preference

**Configuration:**
```python
TelegramConnector(
    bot_token=os.environ["TELEGRAM_BOT_TOKEN"],
    allowed_users=[123456789],  # Your Telegram user ID
    default_trust_level=TrustLevel.SANDBOXED,
    network_enabled=False,
)
```

#### ⚠️ RISKY: Public bot with sandboxed trust

**Scenario:** You run a Discord bot in a public server for demonstration.

- Unknown users can create sessions
- All users can read/write your vault files
- Use only for non-sensitive vaults
- Consider this experimental/demo use case

**Configuration:**
```python
DiscordConnector(
    bot_token=os.environ["DISCORD_BOT_TOKEN"],
    default_trust_level=TrustLevel.SANDBOXED,  # REQUIRED
    network_enabled=False,  # Maximum isolation
)
```

**Warnings:**
- Create a separate vault for public bot access
- Do NOT store sensitive data in this vault
- Monitor bot activity logs regularly
- Expect malicious users to attempt exploits

#### ❌ UNSAFE: Public bot with direct trust

**Scenario:** **NEVER DO THIS**

- Allows arbitrary code execution by strangers
- Complete compromise of your system
- No legitimate use case for public bots with direct trust

---

## Best Practices

### 1. Start with sandboxed trust

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
parachute logs | grep "session_id=" | grep "trust_level=direct"
```

### 4. Limit bot capabilities

Disable network for sandboxed bots unless required:
```python
BotConnector(
    default_trust_level=TrustLevel.SANDBOXED,
    network_enabled=False,  # Most restrictive
)
```

### 5. Use workspaces for sensitive data

Create workspace-specific sessions instead of workspace-less:
```python
# Bot creates session with workspace (directory restriction)
session = await create_session(
    workspace_slug="personal",  # Limited to ~/Parachute/workspaces/personal/
    trust_level=TrustLevel.SANDBOXED,
)
```

**Note:** This requires workspace support in your bot logic.

### 6. Restrict allowed users

For Telegram and Discord, use `allowed_users` to whitelist specific user IDs:
```python
TelegramConnector(
    allowed_users=[123456789, 987654321],  # Only these user IDs can use the bot
    default_trust_level=TrustLevel.SANDBOXED,
)
```

---

## Attack Scenarios

### Scenario 1: Malicious Public Bot User (sandboxed)

**Attacker goal:** Steal data from your vault

**What they can do:**
1. Send message to bot: "List all files in /vault"
2. Agent lists files via MCP `filesystem` tools
3. Attacker requests specific file contents: "Read /vault/secrets.txt"
4. Agent reads and returns file content via MCP

**Mitigation:**
- Don't deploy public bots with sensitive vaults
- Use workspace isolation (when implemented)
- Monitor bot activity logs
- Consider creating a separate "public" vault

**Cannot do:**
- Escape container to host
- Access other users' sessions
- Modify server code
- Install host packages
- Access network (if `network_enabled=False`)

### Scenario 2: Compromised Bot Token (direct trust)

**Attacker goal:** Full server compromise

**What they can do:**
1. Use stolen bot token to send messages
2. Send: "Run `rm -rf ~/Parachute` on the host"
3. Agent executes arbitrary code on host with server privileges
4. Install backdoors, steal credentials, pivot to other systems

**Mitigation:**
- **Never use direct trust for bots**
- Protect bot tokens as secrets
- Rotate tokens immediately if compromised
- Use sandboxed trust as defense-in-depth
- Monitor for unusual activity

### Scenario 3: Bot User Exploits MCP Tool (sandboxed)

**Attacker goal:** Write malicious files to vault

**What they can do:**
1. Send: "Create a file at /vault/.parachute/hooks/pre-session.sh"
2. Agent writes malicious hook script via MCP
3. Hook executes on next session startup with server privileges

**Mitigation:**
- Hooks are disabled in sandboxed mode (no host access)
- Sandboxed agents cannot escape to run hooks on host
- Monitor for unexpected file modifications
- Regular vault backups

---

## Configuration Examples

### Telegram: Private Personal Bot

```python
from parachute.connectors.telegram import TelegramConnector
from parachute.models.session import TrustLevel
import os

connector = TelegramConnector(
    bot_token=os.environ["TELEGRAM_BOT_TOKEN"],
    allowed_users=[123456789],  # Your Telegram user ID only
    default_trust_level=TrustLevel.SANDBOXED,
    network_enabled=True,  # Enable for web search, API calls
)
```

### Discord: Team Bot (Trusted Users)

```python
from parachute.connectors.discord import DiscordConnector
from parachute.models.session import TrustLevel
import os

connector = DiscordConnector(
    bot_token=os.environ["DISCORD_BOT_TOKEN"],
    allowed_users=[
        111222333444555666,  # Alice
        777888999000111222,  # Bob
    ],
    default_trust_level=TrustLevel.SANDBOXED,  # Still sandboxed for defense-in-depth
    network_enabled=True,
)
```

### Matrix: Public Demo Bot

```python
from parachute.connectors.matrix import MatrixConnector
from parachute.models.session import TrustLevel
import os

# WARNING: This configuration allows ANYONE to use the bot
# Only deploy with a separate demo vault containing non-sensitive data

connector = MatrixConnector(
    homeserver_url="https://matrix.org",
    user_id="@parachute-demo:matrix.org",
    access_token=os.environ["MATRIX_ACCESS_TOKEN"],
    default_trust_level=TrustLevel.SANDBOXED,  # REQUIRED
    network_enabled=False,  # Maximum isolation
)
```

---

## Future Enhancements

Planned improvements for safer multi-user bot deployments:

- [ ] Per-user vault isolation (#TBD)
- [ ] Workspace-level ACLs (#TBD)
- [ ] Session ownership and authorization (#TBD)
- [ ] Audit logging (who created which session) (#TBD)
- [ ] Rate limiting per bot user (#TBD)
- [ ] Token-based authentication for bot users (#TBD)
- [ ] Read-only bot mode (no file writes) (#TBD)

---

## Summary

| Configuration | Safety | Use Case |
|---------------|--------|----------|
| Private bot + sandboxed | ✅ Safe | Personal use, trusted single user |
| Private bot + direct | ⚠️ Risky | Only if you fully trust yourself |
| Public bot + sandboxed | ⚠️ Risky | Demo/experimental, non-sensitive vault |
| Public bot + direct | ❌ NEVER | No legitimate use case |

**Default to sandboxed trust for all bots. Never use direct trust for public bots.**

For questions or security concerns, file an issue on GitHub: https://github.com/OpenParachutePBC/parachute-computer/issues
