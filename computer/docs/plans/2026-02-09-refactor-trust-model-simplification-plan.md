---
title: "refactor: Trust Model Simplification & Unified Vault Path"
type: refactor
date: 2026-02-09
---

# Trust Model Simplification & Unified Vault Path

## Overview

Collapse the three-tier trust model (full/vault/sandboxed) into a binary model (trusted/untrusted) and unify vault paths via a `/vault` symlink so bare metal and Docker agents see identical filesystem paths. Docker IS the permission boundary — both modes bypass SDK permission checks.

## Problem Statement

The current architecture has two compounding problems:

1. **Three trust levels create confusion.** "Vault" trust runs on bare metal with directory restrictions — a half-measure that's neither secure (still bare metal) nor convenient (restricted tools). Users must understand three levels when the real question is binary: do you trust this agent?

2. **Working directories differ between execution contexts.** Bare metal uses `/Users/parachute/Parachute/Projects/foo` while Docker uses `/vault/Projects/foo`. This causes different SDK transcript paths, complex path resolution logic, and agents seeing different paths depending on trust level.

## Proposed Solution

### Trust: Binary model

| Old | New | Runtime |
|-----|-----|---------|
| `full` | `trusted` | Bare metal, bypass permissions |
| `vault` | _(removed)_ | — |
| `sandboxed` | `untrusted` | Docker container, bypass permissions |

### Paths: Unified via symlink

```
Host:     /vault → ~/Parachute (symlink, created by install.sh)
Bare metal CWD: /vault/Projects/foo
Docker CWD:     /vault/Projects/foo (same path, mounted volume)
DB stores:      /vault/Projects/foo (absolute, consistent)
```

### Trust defaults

| Context | Default | Rationale |
|---------|---------|-----------|
| Native app sessions | trusted | User at their own machine |
| Telegram bot DMs | untrusted | Remote access, isolate |
| Telegram bot groups | untrusted | Multiple users, must isolate |
| Discord bot | untrusted | Remote access |
| Workspace override | Either | Workspace config can force trusted or untrusted |

## Technical Approach

### Architecture

```
Before:
  TrustLevel enum: FULL (0) → VAULT (1) → SANDBOXED (2)
  Path resolution: DB stores "Projects/foo" (relative)
                   resolve_working_directory() → absolute for bare metal
                   make_working_directory_relative() → relative for Docker
  Capability filter: TRUST_ORDER = {"full": 0, "vault": 1, "sandboxed": 2}
  Orchestrator: 3-way routing (full → bare metal, vault → bare metal restricted, sandboxed → Docker)

After:
  TrustLevel enum: TRUSTED → UNTRUSTED
  Path resolution: DB stores "/vault/Projects/foo" (absolute, consistent)
                   No translation needed
  Capability filter: TRUST_ORDER = {"trusted": 0, "untrusted": 1}
  Orchestrator: 2-way routing (trusted → bare metal, untrusted → Docker)
```

### Implementation Phases

#### Phase 1: `/vault` Symlink & Install Changes

- [x]`install.sh`: After venv setup (line 54), add `/vault` symlink creation
  - Detect vault path from config or prompt
  - `sudo ln -sf "$VAULT_PATH" /vault`
  - Only on macOS; skip on Linux if `/vault` already exists (Lima VM mounts)
  - Add to `parachute install` interactive flow (`cli.py`)
- [x]`config.py`: No changes needed — `vault_path` setting continues to work, but code reads `/vault` at runtime

```bash
# install.sh addition after line 54
if [[ "$(uname)" == "Darwin" ]] && [ ! -L /vault ]; then
    echo ""
    echo "Creating /vault symlink (requires sudo)..."
    sudo ln -sf "$VAULT_PATH" /vault
fi
```

#### Phase 2: Trust Enum & Model Changes

**Python models (`computer/`):**

- [x]`models/session.py:14-22` — Replace `TrustLevel` enum:
  ```python
  class TrustLevel(str, Enum):
      TRUSTED = "trusted"
      UNTRUSTED = "untrusted"
  ```
- [x]`models/session.py:34-38` — Update `SessionPermissions.trust_level` field default and description
- [x]`models/session.py:78-89` — Simplify `effective_trust_level` (no legacy `trust_mode` dance — just return trust_level)
- [x]`models/session.py:91-141` — Simplify `can_read`/`can_write`/`can_bash`: trusted = allow all, untrusted = Docker handles it (these methods become nearly trivial)
- [x]`models/session.py:206-210` — Update `Session.trust_level` field description
- [x]`models/session.py:242-249` — Update `get_trust_level()` backward compat mapping
- [x]`models/workspace.py:13` — Update `TrustLevelStr = Literal["trusted", "untrusted"]`
- [x]`models/workspace.py:73-76` — Update `WorkspaceConfig.trust_level` default and description
- [x]`connectors/config.py:14` — Update `TrustLevelStr` literal
- [x]`connectors/config.py:25-28` — Update `TelegramConfig` trust defaults to `"untrusted"`
- [x]`connectors/config.py:39-42` — Update `DiscordConfig` trust defaults to `"untrusted"`
- [x]`connectors/base.py:98-100` — Update `BotConnector.__init__` trust param defaults to `"untrusted"`

**Dart models (`app/`):**

- [x]`settings/models/trust_level.dart:5-8` — Replace enum:
  ```dart
  enum TrustLevel {
    trusted,
    untrusted;
  }
  ```
- [x]`settings/models/trust_level.dart:10-33` — Update `displayName`, `description`, `icon`, `iconColor` for 2 values
- [x]`settings/models/trust_level.dart:34-40` — Update `fromString()` default to `TrustLevel.trusted`

#### Phase 3: Capability Filter Simplification

- [x]`core/capability_filter.py:20` — Update `TRUST_ORDER`:
  ```python
  TRUST_ORDER: dict[str, int] = {"trusted": 0, "untrusted": 1}
  ```
- [x]`core/capability_filter.py:39-80` — Update `filter_by_trust_level()` docstring and logic for 2 levels
- [x]MCP trust annotations in `.mcp.json` — Update any `"trust_level": "vault"` → `"trusted"`, `"trust_level": "sandboxed"` → `"untrusted"`, `"trust_level": "full"` → `"trusted"`

#### Phase 4: Path Unification

- [x]`core/session_manager.py:45-78` — Simplify `resolve_working_directory()`:
  - If path starts with `/vault/`, use as-is
  - If relative (legacy), prepend `/vault/`
  - Drop vault_path-based resolution
- [x]`core/session_manager.py:80-109` — Remove `make_working_directory_relative()` entirely
- [x]`core/orchestrator.py:670-672` — Remove `sandbox_wd = self.session_manager.make_working_directory_relative(...)` — just use `effective_working_dir` directly since it's already `/vault/...`
- [x]`core/sandbox.py:204-205` — Remove `/vault/` prefix from `PARACHUTE_CWD` env var (path already starts with `/vault/`)
- [x]`core/sandbox.py:105-131` — Update `_build_mounts()` — paths are already `/vault/...`, simplify mount logic

#### Phase 5: Orchestrator Trust Routing

- [x]`core/orchestrator.py:538-563` — Simplify trust resolution:
  ```python
  session_trust = session.get_trust_level()
  if workspace_config and workspace_config.trust_level:
      workspace_trust = TrustLevel(workspace_config.trust_level)
      if trust_rank(workspace_trust) > trust_rank(session_trust):
          session_trust = workspace_trust
  # Client can only restrict, never escalate
  if trust_level:
      requested = TrustLevel(trust_level)
      if trust_rank(requested) >= trust_rank(session_trust):
          session_trust = requested
  effective_trust = session_trust.value
  ```
  Logic is the same shape — just 2 values now instead of 3.

- [x]`core/orchestrator.py:664-777` — Update sandbox routing:
  - `if effective_trust == "untrusted":` (was `"sandboxed"`)
  - Remove vault fallback on Docker unavailable — if untrusted and no Docker, error out (don't silently degrade)
  - Remove `make_working_directory_relative()` call — path is already `/vault/...`

#### Phase 6: Database Migration

- [x]`db/database.py:195+` — Add migration (v14):
  ```python
  # Migration: Trust model simplification (v14)
  # Map old trust levels to new: full → trusted, vault → trusted, sandboxed → untrusted
  async with self._connection.execute("SELECT version FROM schema_version WHERE version = 14"):
      row = await cursor.fetchone()
  if not row:
      await self._connection.execute(
          "UPDATE sessions SET trust_level = 'trusted' WHERE trust_level IN ('full', 'vault')"
      )
      await self._connection.execute(
          "UPDATE sessions SET trust_level = 'untrusted' WHERE trust_level = 'sandboxed'"
      )
      # Also update pairing_requests
      await self._connection.execute(
          "UPDATE pairing_requests SET approved_trust_level = 'trusted' WHERE approved_trust_level IN ('full', 'vault')"
      )
      await self._connection.execute(
          "UPDATE pairing_requests SET approved_trust_level = 'untrusted' WHERE approved_trust_level = 'sandboxed'"
      )
      await self._connection.execute(
          "INSERT OR IGNORE INTO schema_version (version, applied_at) VALUES (14, datetime('now'))"
      )
      await self._connection.commit()
      logger.info("Migrated trust levels: full/vault → trusted, sandboxed → untrusted (v14)")
  ```

- [x]`db/database.py` — Add path migration (v15):
  ```python
  # Migration: Unify working_directory paths to /vault/... format (v15)
  # Convert relative paths (e.g., "Projects/foo") to absolute ("/vault/Projects/foo")
  await self._connection.execute("""
      UPDATE sessions
      SET working_directory = '/vault/' || working_directory
      WHERE working_directory IS NOT NULL
        AND working_directory != ''
        AND working_directory NOT LIKE '/vault/%'
        AND working_directory NOT LIKE '/%'
  """)
  # Convert old absolute paths to /vault/ paths
  # e.g., /Users/parachute/Parachute/Projects/foo → /vault/Projects/foo
  # This requires knowing the old vault_path — use vault_root column if available
  ```
  Note: Absolute path migration is best-effort. Old absolute paths that don't match current vault_root will be left as-is.

#### Phase 7: Dead Code Removal

- [x]`models/session.py:68-73` — Remove deprecated `trust_mode` field
- [x]`models/session.py:77-89` — Remove `effective_trust_level` property (just return `trust_level` directly)
- [x]`models/session.py:91-141` — Simplify permission methods: trusted allows all, untrusted is Docker-managed
- [x]`core/session_manager.py:80-109` — Delete `make_working_directory_relative()` method
- [x]Remove all `from parachute.core.capability_filter import trust_rank` calls that are no longer needed after simplification
- [x]Search for string literals `"full"`, `"vault"`, `"sandboxed"` across both repos and update

#### Phase 8: App UI Changes

- [x]`settings/models/trust_level.dart` — 2-value enum (done in Phase 2)
- [x]`chat/widgets/session_config_sheet.dart` — Trust selector: 2 segments instead of 3
- [x]`chat/screens/chat_screen.dart` — Trust display: 2 options
- [x]`chat/widgets/unified_session_settings.dart` — Trust state management
- [x]`settings/widgets/bot_connectors_section.dart` — Per-platform trust dropdowns: 2 options
- [x]`chat/widgets/new_chat_sheet.dart` — Trust selector: 2 segments
- [x]`chat/providers/chat_message_providers.dart` — `ChatState.trustLevel` handling

#### Phase 9: API Updates

- [x]`api/sessions.py:18` — Update `SessionConfigUpdate.trust_level` description
- [x]`api/sessions.py` — Validate trust_level values in config update and activate endpoints
- [x]Workspace API — Update trust_level validation to accept only `"trusted"` / `"untrusted"`

#### Phase 10: Backward Compatibility

- [x]`models/session.py` — `get_trust_level()` maps old values:
  ```python
  def get_trust_level(self) -> TrustLevel:
      if self.trust_level:
          # Map legacy values
          legacy_map = {"full": "trusted", "vault": "trusted", "sandboxed": "untrusted"}
          mapped = legacy_map.get(self.trust_level, self.trust_level)
          try:
              return TrustLevel(mapped)
          except ValueError:
              return TrustLevel.TRUSTED
      return TrustLevel.TRUSTED
  ```
- [x]`settings/models/trust_level.dart` — `fromString()` maps old values:
  ```dart
  static TrustLevel fromString(String? value) {
    if (value == null) return TrustLevel.trusted;
    // Map legacy values
    if (value == 'full' || value == 'vault') return TrustLevel.trusted;
    if (value == 'sandboxed') return TrustLevel.untrusted;
    return TrustLevel.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TrustLevel.trusted,
    );
  }
  ```

## Acceptance Criteria

### Functional Requirements

- [x]`install.sh` creates `/vault` symlink to vault path on macOS
- [x]Trust enum has exactly 2 values: `trusted` and `untrusted`
- [x]Native app sessions default to `trusted`
- [x]Bot sessions default to `untrusted`
- [x]Workspace trust override works with 2 values (floor enforcement)
- [x]Trust selector UI shows 2 segments everywhere
- [x]Docker sandbox routing activates for `untrusted` (not `sandboxed`)
- [x]Bare metal routing activates for `trusted` (not `full`)
- [x]When Docker unavailable and trust is `untrusted`, error instead of silently downgrading
- [x]DB migration converts existing `full`/`vault` → `trusted`, `sandboxed` → `untrusted`
- [x]Working directories stored as `/vault/...` absolute paths
- [x]Path resolution works without `make_working_directory_relative()`
- [x]`bots.yaml` trust defaults updated to `trusted`/`untrusted`
- [x]Legacy trust values in DB/API are mapped correctly via backward compat

### Non-Functional Requirements

- [x]No data loss during migration
- [x]Existing sessions continue to work after migration
- [x]Server starts without errors after migration
- [x]App displays correct trust level for migrated sessions

## Dependencies & Prerequisites

- Docker must be installed for untrusted sessions (no more silent fallback to vault)
- `install.sh` requires `sudo` for `/vault` symlink creation on macOS
- Must coordinate app + server deployment (app needs updated enum before server rejects old values)

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| `/vault` symlink conflicts with existing dir | Install fails | Check if `/vault` exists first, prompt user |
| DB migration corrupts working_directory | Sessions can't find files | Backup DB before migration; relative→absolute is safe SQL |
| Legacy API clients send "full"/"vault"/"sandboxed" | 400 errors | Backward compat mapping in `get_trust_level()` and API validation |
| Docker not available, untrusted sessions fail | Bot sessions stop working | Clear error message; recommend Docker install |
| Linux (Lima VM) `/vault` already mounted | Conflict | Skip symlink if `/vault` exists and is a mount point |

## Institutional Learnings Applied

From `MEMORY.md`:
- **Sandbox session finalization**: `finalize_session` must UPDATE not INSERT for connector-created sessions — unchanged by this refactor
- **Docker CWD 3-part setup**: mount + PARACHUTE_CWD + entrypoint chdir — path unification simplifies this (no more relative→absolute dance)
- **Async generator race condition**: Cleanup before yield for final events — unchanged
- **Workspace trust floor enforcement**: UI disables less-restrictive options — same logic, fewer options

## Files Modified

| File | Repo | Phase | Changes |
|------|------|-------|---------|
| `install.sh` | computer | 1 | `/vault` symlink creation |
| `models/session.py` | computer | 2, 7, 10 | TrustLevel enum → 2 values, remove trust_mode, backward compat |
| `models/workspace.py` | computer | 2 | TrustLevelStr → 2 values |
| `connectors/config.py` | computer | 2 | TrustLevelStr, default trust levels |
| `connectors/base.py` | computer | 2 | Default trust params |
| `core/capability_filter.py` | computer | 3 | TRUST_ORDER → 2 entries |
| `core/session_manager.py` | computer | 4, 7 | Simplify resolve_working_directory, remove make_working_directory_relative |
| `core/orchestrator.py` | computer | 4, 5 | Trust routing, path handling |
| `core/sandbox.py` | computer | 4 | Path/mount simplification |
| `db/database.py` | computer | 6 | v14 trust migration, v15 path migration |
| `api/sessions.py` | computer | 9 | Validation updates |
| `settings/models/trust_level.dart` | app | 2, 10 | 2-value enum, backward compat |
| `chat/widgets/session_config_sheet.dart` | app | 8 | 2-segment trust selector |
| `chat/screens/chat_screen.dart` | app | 8 | Trust display |
| `chat/widgets/unified_session_settings.dart` | app | 8 | Trust state |
| `settings/widgets/bot_connectors_section.dart` | app | 8 | 2-option trust dropdowns |
| `chat/widgets/new_chat_sheet.dart` | app | 8 | 2-segment trust selector |
| `chat/providers/chat_message_providers.dart` | app | 8 | Trust handling |

## Verification

1. **Symlink**: `ls -la /vault` → shows symlink to vault path
2. **Server starts**: `parachute server -f` → no errors, migration logs show v14/v15
3. **Existing sessions**: List sessions → trust levels show "trusted"/"untrusted" (no "full"/"vault"/"sandboxed")
4. **New native chat**: Create chat → defaults to trusted, runs on bare metal
5. **New bot DM**: Send Telegram message → session created as untrusted, runs in Docker
6. **Trust selector**: Open session config → 2 segments (Trusted / Untrusted)
7. **Workspace override**: Set workspace to untrusted → sessions in that workspace run in Docker
8. **Path consistency**: `session.working_directory` = `/vault/Projects/foo` for both trusted and untrusted sessions
9. **Docker unavailable + untrusted**: Should error, not silently degrade to bare metal
10. **Legacy values**: Manually insert session with `trust_level='full'` → `get_trust_level()` returns `TRUSTED`

## References

### Internal References

- Brainstorm: `docs/brainstorms/2026-02-09-trust-model-simplification-brainstorm.md`
- Trust enum: `computer/parachute/models/session.py:14-22`
- Workspace trust: `computer/parachute/models/workspace.py:13,73-76`
- Capability filter: `computer/parachute/core/capability_filter.py:20,39-80`
- Path resolution: `computer/parachute/core/session_manager.py:45-109`
- Orchestrator routing: `computer/parachute/core/orchestrator.py:538-563,664-777`
- Sandbox config: `computer/parachute/core/sandbox.py:33-46,105-131,204-205`
- DB migrations: `computer/parachute/db/database.py:195-312`
- Bot trust defaults: `computer/parachute/connectors/base.py:98-100`
- Bot config: `computer/parachute/connectors/config.py:14,25-28,39-42`
- API validation: `computer/parachute/api/sessions.py:15-29`
- Dart trust enum: `app/lib/features/settings/models/trust_level.dart:5-41`
- Install script: `computer/install.sh:54+`
