---
title: "Storage Restructure: vault → ~/.parachute"
type: refactor
date: 2026-03-03
issue: 170
---

# Storage Restructure: vault → ~/.parachute

Remove the `~/Parachute` vault abstraction. All system data moves to `~/.parachute/`. Session metadata migrates from SQLite to the Kuzu graph DB. The user's home directory becomes the natural filesystem root with no imposed structure.

## Acceptance Criteria

- [ ] Server reads config from `~/.parachute/config.yaml` (not `~/Parachute/.parachute/config.yaml`)
- [ ] Graph DB lives at `~/.parachute/graph/parachute.kz`
- [ ] No SQLite dependency — all session metadata in Kuzu
- [ ] JSONL transcripts stored under `~/.parachute/sessions/`
- [ ] Sandbox env homes at `~/.parachute/sandbox/envs/<slug>/home/`
- [ ] Modules loaded from `~/.parachute/modules/`
- [ ] `vault_path` concept removed from `Settings` and all call sites
- [ ] Working directories stored as real absolute paths (not `/vault/...` prefixes)
- [ ] Auto-migration runs on first boot if `~/Parachute/.parachute/` exists
- [ ] Flutter file browser roots at `~/` with no vault scope restriction
- [ ] All existing data accessible after migration

---

## Problem Statement

`~/Parachute` was designed as an Obsidian-style vault — a user-facing folder that is the source of truth for all data. This model no longer fits: Brain, Daily, and Chat all store content in Kuzu. The vault now only contains hidden system directories (`.parachute/`, `.brain/`, `.claude/`, `.modules/`), making it confusing and unnecessary friction for users.

The vault concept also imposes an artificial access boundary. Sessions are restricted to `~/Parachute`, preventing natural navigation of the user's real filesystem.

---

## Proposed Solution

**Five implementation phases, each independently deployable:**

1. **Path restructure** — Move server paths from vault-relative to `~/.parachute/`-relative. Replace `vault_path` in config/settings with `parachute_dir`.
2. **SQLite → Kuzu migration** — Replace `database.py` + `SessionManager` with graph-backed equivalents.
3. **Data migration script** — One-time auto-migration on first boot.
4. **Flutter app updates** — Remove vault concept from `FileSystemService`; file browser roots at `~/`.
5. **CLI + install updates** — Update `parachute config`, `daemon.py`, `install.sh`.

---

## New Directory Layout

```
~/.parachute/
├── config.yaml                    # Server config (was vault/.parachute/config.yaml)
├── .token                         # Claude OAuth token (was vault/.parachute/.token)
├── .config.lock                   # Atomic config write lock
├── module_hashes.json             # Module approval hashes
├── plugin-manifests/              # Plugin metadata
├── agents/                        # Custom SDK agents
├── skills/                        # Custom skills
├── mcp.json                       # MCP server configurations
├── CLAUDE.md                      # Optional server instructions
├── logs/                          # Daemon logs
├── graph/
│   └── parachute.kz               # Unified Kuzu graph DB
├── sessions/                      # SDK JSONL transcripts (was vault/.claude/)
├── sandbox/
│   └── envs/                      # Per-container persistent homes
└── modules/                       # Installed vault modules (was vault/.modules/)
```

---

## Implementation Phases

### Phase 1: Python Server — Path Restructure

**Goal:** Replace `vault_path` with `parachute_dir = ~/.parachute`. No DB changes yet.

#### 1.1 `computer/parachute/config.py`

- Remove `_resolve_vault_path()` function
- Remove `vault_path` from `CONFIG_KEYS` and `Settings` fields
- Add `parachute_dir` property: `Path.home() / ".parachute"` (not configurable)
- Rename `_load_yaml_config(vault_path)` → `_load_yaml_config(parachute_dir)`
- Rename `_load_token(vault_path)` → `_load_token(parachute_dir)`
- Update `save_yaml_config*`, `save_token`, `get_config_path` to take `parachute_dir`
- Update `Settings.database_path` → `parachute_dir / "sessions.db"` (temporary, removed in Phase 2)
- Update `Settings.config_dir` → `parachute_dir`
- Update `Settings.log_dir` → `parachute_dir / "logs"`
- Update config bootstrap in `_inject_yaml_config` to read from `~/.parachute/config.yaml`

**Migration bootstrap in `_inject_yaml_config`:** If `~/.parachute/config.yaml` doesn't exist but `~/Parachute/.parachute/config.yaml` does, copy key fields (port, host, log_level, auth_mode, default_model) but NOT vault_path.

#### 1.2 `computer/parachute/server.py`

- Replace all `settings.vault_path` with `settings.parachute_dir` (or specific sub-paths)
- Graph DB path: `settings.parachute_dir / "graph" / "parachute.kz"` (was `vault_path / ".brain" / "brain.lbug"`)
- Module loader: `ModuleLoader(settings.parachute_dir)`
- Hook runner: `HookRunner(settings.parachute_dir)`
- Bots API: `init_bots_api(parachute_dir=settings.parachute_dir, ...)`
- Scheduler: `init_scheduler(settings.parachute_dir)`
- Startup dir creation: `(settings.parachute_dir).mkdir(parents=True, exist_ok=True)`
- Remove "Vault path:" log line; add "Parachute dir: ~/.parachute"

#### 1.3 `computer/parachute/core/module_loader.py`

- `ModuleLoader.__init__` takes `parachute_dir: Path` (was `vault_path`)
- `self.modules_dir = parachute_dir / "modules"` (was `vault_path / ".modules"`)
- `self._hash_file = parachute_dir / "module_hashes.json"` (was `vault_path / ".parachute" / "module_hashes.json"`)
- Module instances still receive their needed paths (graph db, etc.) via registry — no vault_path passed to modules

#### 1.4 `computer/parachute/core/sandbox.py`

- `DockerSandbox.__init__` takes `parachute_dir: Path` (was `vault_path`)
- `SANDBOX_DATA_DIR` constant replaced with `self.sandbox_dir = parachute_dir / "sandbox"`
- Container home dirs: `parachute_dir / "sandbox" / "envs" / slug / "home"`
- Remove vault volume mounts (containers currently mount vault read-only — no longer needed)
- Container envs table lookup: update to use graph DB (Phase 2); for now, keep SQLite but move path

#### 1.5 `computer/parachute/core/session_manager.py`

- Remove `vault_path` parameter (no longer needed for path resolution)
- `resolve_working_directory`: Drop `/vault/...` convention. Real absolute paths stored as-is. Empty/None → `Path.home()`.
- JSONL transcript paths: `parachute_dir / "sessions"` instead of `vault_path / ".claude"`
- Update `write_sdk_transcript()` and `load_sdk_transcript()` to use new sessions path

#### 1.6 `computer/parachute/core/orchestrator.py`

- Remove `vault_path` parameter from constructor
- Pass `parachute_dir` to `SessionManager`, `DockerSandbox`, `ModuleLoader`
- Update working directory resolution

#### 1.7 `computer/parachute/lib/vault_utils.py`

- Remove `validate_path()` vault-boundary check (no vault scope)
- Remove `get_vault_stats()` (references Chat/Daily/Build module dirs)
- Remove `list_vault_files()` or rename to `list_dir_files()` without vault dependency
- `read_document()` / `write_document()` take absolute path instead of (vault_path, relative_path)

#### 1.8 `computer/parachute/api/filesystem.py`

- Update path resolution: drop `/vault/...` convention
- File operations take real absolute paths under `~/`
- No vault boundary enforcement (sessions are per-session context now)

#### 1.9 Other files with `vault_path` references

Search and update:
- `computer/parachute/api/settings.py` — config path references
- `computer/parachute/api/modules.py` — module list endpoint
- `computer/parachute/api/plugins.py` — plugin installer
- `computer/parachute/core/plugin_installer.py` — plugin paths
- `computer/parachute/lib/mcp_loader.py` — MCP config at `~/.parachute/mcp.json`
- `computer/parachute/lib/context_loader.py` — context loading paths
- `computer/parachute/core/skills.py` — skills at `~/.parachute/skills/`
- `computer/parachute/connectors/` — remove vault_path params from bot connectors
- `computer/parachute/lib/server_config.py` — config at `~/.parachute/`
- `computer/parachute/lib/credentials.py` — token at `~/.parachute/.token`
- `computer/parachute/core/hooks/runner.py` — hooks at `~/.parachute/hooks/`
- `computer/parachute/daemon.py` — daemon config paths
- `computer/modules/brain/`, `chat/`, `daily/` — modules receive graph service via registry, not vault_path

---

### Phase 2: SQLite → Kuzu Migration

**Goal:** Remove `database.py` and all SQLite usage. All session metadata in Kuzu graph DB.

#### 2.1 Kuzu Schema for Session Metadata

Add to `GraphService` initialization (in `server.py` lifespan, after graph connects):

```python
# Session metadata tables
await graph.ensure_node_table("Parachute_Session", {
    "session_id": "STRING",      # Primary key (SDK session ID)
    "title": "STRING",
    "module": "STRING",
    "source": "STRING",
    "working_directory": "STRING",
    "model": "STRING",
    "message_count": "INT64",
    "archived": "BOOLEAN",
    "created_at": "STRING",
    "last_accessed": "STRING",
    "continued_from": "STRING",
    "agent_type": "STRING",
    "trust_level": "STRING",
    "metadata_json": "STRING",   # JSON-encoded dict
}, primary_key="session_id")

await graph.ensure_node_table("Session_Tag", {
    "tag_key": "STRING",         # Primary key: "{session_id}:{tag}"
    "session_id": "STRING",
    "tag": "STRING",
}, primary_key="tag_key")

await graph.ensure_node_table("Session_Context", {
    "context_id": "STRING",      # Primary key: "{session_id}:{path}"
    "session_id": "STRING",
    "folder_path": "STRING",
    "label": "STRING",
}, primary_key="context_id")

await graph.ensure_node_table("Container_Env", {
    "slug": "STRING",            # Primary key
    "label": "STRING",
    "session_id": "STRING",
    "created_at": "STRING",
    "last_used": "STRING",
}, primary_key="slug")

await graph.ensure_node_table("Pairing_Request", {
    "request_id": "STRING",      # Primary key
    "platform": "STRING",
    "user_id": "STRING",
    "user_name": "STRING",
    "code": "STRING",
    "created_at": "STRING",
    "expires_at": "STRING",
    "approved": "BOOLEAN",
}, primary_key="request_id")
```

#### 2.2 New `GraphSessionStore` class

Create `computer/parachute/db/graph_sessions.py`:

- Wraps `GraphService` to provide `Database`-compatible CRUD interface
- Methods: `get_session()`, `create_session()`, `update_session()`, `delete_session()`, `list_sessions()`, `add_tag()`, `remove_tag()`, `get_tags()`, `add_context()`, `remove_context()`, `get_contexts()`, `create_container_env()`, `get_container_env()`, `list_container_envs()`, `create_pairing_request()`, `get_pairing_request()`, `approve_pairing_request()`
- Session list queries support: tag filtering, module filtering, archived filtering, pagination
- All queries via `graph.execute_cypher()`

#### 2.3 Update `SessionManager`

- Replace `Database` dependency with `GraphSessionStore`
- Remove `self.db = database` → `self.sessions = graph_session_store`
- All method calls go through graph store

#### 2.4 Update `server.py` lifespan

- Remove `init_database()` / `close_database()` calls
- Remove `database` from `Orchestrator` constructor
- Remove `app.state.database`
- Create `GraphSessionStore(graph)` after graph connects
- Pass `graph_session_store` to `Orchestrator` and `SessionManager`

#### 2.5 Update all API routes

Files that use `request.app.state.database` or `db` parameter:
- `computer/parachute/api/sessions.py` — all session CRUD
- `computer/parachute/api/bots.py` — pairing requests
- `computer/parachute/api/context_folders.py` — session contexts

Replace `Database` with `GraphSessionStore` in dependency injection.

#### 2.6 Remove SQLite

- Delete `computer/parachute/db/database.py`
- Delete `computer/parachute/db/__init__.py` (or simplify to just export `GraphService`)
- Remove `aiosqlite` from `pyproject.toml`
- Remove `db_path` / `database_path` from `Settings`
- Remove `chunks` and `index_manifest` tables (RAG — unused)

---

### Phase 3: Auto-Migration Script

**Goal:** On first boot, detect old vault and migrate data to `~/.parachute/`.

Create `computer/parachute/core/migration.py`:

```python
async def migrate_if_needed(parachute_dir: Path) -> bool:
    """
    Run one-time migration from ~/Parachute/ if ~/.parachute/ doesn't exist.
    Returns True if migration ran.
    """
    old_vault = Path.home() / "Parachute"
    old_parachute = old_vault / ".parachute"

    if parachute_dir.exists() or not old_parachute.exists():
        return False

    logger.info("Migrating from ~/Parachute/ to ~/.parachute/...")
    parachute_dir.mkdir(parents=True, exist_ok=True)

    # 1. Copy config files (excluding vault_path key)
    _migrate_config(old_parachute / "config.yaml", parachute_dir / "config.yaml")
    _copy_if_exists(old_parachute / ".token", parachute_dir / ".token", chmod=0o600)
    _copy_if_exists(old_parachute / "module_hashes.json", parachute_dir / "module_hashes.json")
    _copy_dir_if_exists(old_parachute / "plugin-manifests", parachute_dir / "plugin-manifests")
    _copy_dir_if_exists(old_parachute / "agents", parachute_dir / "agents")
    _copy_dir_if_exists(old_parachute / "logs", parachute_dir / "logs")

    # 2. Copy graph DB
    old_graph = old_vault / ".brain" / "brain.lbug"
    new_graph = parachute_dir / "graph" / "parachute.kz"
    if old_graph.exists():
        new_graph.parent.mkdir(exist_ok=True)
        shutil.copy2(old_graph, new_graph)
        # Also copy WAL if present
        _copy_if_exists(old_graph.parent / "brain.lbug.wal", new_graph.parent / "parachute.kz.wal")

    # 3. Copy JSONL transcripts
    old_sessions = old_vault / ".claude"
    new_sessions = parachute_dir / "sessions"
    if old_sessions.exists():
        shutil.copytree(old_sessions, new_sessions, dirs_exist_ok=True)

    # 4. Copy modules
    old_modules = old_vault / ".modules"
    new_modules = parachute_dir / "modules"
    if old_modules.exists():
        shutil.copytree(old_modules, new_modules, dirs_exist_ok=True)

    # 5. Copy skills
    old_skills = old_vault / ".skills"
    new_skills = parachute_dir / "skills"
    if old_skills.exists():
        shutil.copytree(old_skills, new_skills, dirs_exist_ok=True)

    # 6. Copy mcp.json
    _copy_if_exists(old_vault / ".mcp.json", parachute_dir / "mcp.json")

    # 7. SQLite → Kuzu migration (runs after graph is connected)
    # NOTE: This is called separately after GraphService connects, passing the old db path

    logger.info("Migration complete. Old ~/Parachute/ preserved — safe to archive manually.")
    return True


async def migrate_sqlite_to_graph(
    old_db_path: Path,
    graph: GraphService,
) -> int:
    """Read SQLite sessions.db and import into Kuzu. Returns count of sessions migrated."""
    if not old_db_path.exists():
        return 0

    import aiosqlite
    count = 0

    async with aiosqlite.connect(old_db_path) as db:
        db.row_factory = aiosqlite.Row

        # Migrate sessions
        async with db.execute("SELECT * FROM sessions") as cursor:
            async for row in cursor:
                await graph.execute_cypher(
                    "MERGE (s:Parachute_Session {session_id: $session_id}) "
                    "SET s.title = $title, s.module = $module, ...",
                    dict(row)
                )
                count += 1

        # Migrate tags, contexts, container_envs, pairing_requests
        # ... similar pattern

    logger.info(f"Migrated {count} sessions from SQLite to Kuzu")
    return count
```

Call in `server.py` lifespan (before graph schema registration):
```python
from parachute.core.migration import migrate_if_needed
await migrate_if_needed(settings.parachute_dir)
# Then connect graph, run schema, then:
old_db = Path.home() / "Parachute" / "Chat" / "sessions.db"
await migrate_sqlite_to_graph(old_db, graph)
```

---

### Phase 4: Flutter App Updates

**Goal:** Remove vault concept; file browser opens at `~/`.

#### 4.1 `app/lib/core/services/file_system_service.dart`

- Remove `ModuleType` enum (no more module-specific subfolder logic)
- Remove `_moduleFolderName` / `_defaultModuleFolderName` concepts
- Remove `Daily` and `Chat` subfolder configs
- `getRootPath()` → returns `~/` (home dir) directly, no subfolder
- `_getDefaultVaultPath()` → rename `_getDefaultHomePath()`, return `$HOME` on all desktop platforms
- Remove vault path from SharedPreferences (or migrate stored vault path → home path)
- Audio asset paths: Keep `~/Daily/assets/` or use system temp — leave for Daily module to decide
- Keep secure bookmark logic (macOS needs it for sandboxed app file access)

#### 4.2 `app/lib/features/vault/services/file_browser_service.dart`

- Rename `isWithinVault()` → `isWithinHome()` — check `path.startsWith(HOME)`
- Remove vault scope from `readFileAsString()` and `writeFile()` security checks
- `getInitialPath()` → returns home dir
- Update display path to show `~` for home (already works)

#### 4.3 `app/lib/features/settings/widgets/vault_settings_section.dart`

- Rename to `storage_settings_section.dart`
- Remove vault path picker (no configurable vault)
- Show `~/.parachute/` as the system data location (info only, not editable)

#### 4.4 `app/lib/features/chat/models/working_directory.dart`

- Remove `isVault` concept / `type == 'vault'` references
- `WorkingDirectory.type` simplifies to `'recent'` or `'pinned'`
- `DirectoriesInfo.homeVault` → `homeDir`
- Default directory shown = home dir

#### 4.5 `app/lib/features/chat/widgets/directory_picker.dart`

- Default picker starts at `~/`
- Remove "Vault" label/category

#### 4.6 API endpoint: `/api/directories`

- Update to return home dir instead of vault dir
- `homeVault` → `homeDir` in response JSON
- Type `'vault'` → `'home'`

---

### Phase 5: CLI & Install Updates

#### 5.1 `computer/parachute/cli.py`

- `parachute config set vault_path` → remove this config key
- `parachute config get/set` — update to use `~/.parachute/config.yaml`
- `parachute server status` — show `~/.parachute/` path instead of vault
- `parachute setup-token` — write to `~/.parachute/.token`

#### 5.2 `computer/parachute/daemon.py`

- Look for config at `~/.parachute/config.yaml`
- Log dir at `~/.parachute/logs/`
- PID file at `~/.parachute/parachute.pid`

#### 5.3 `computer/install.sh`

- Create `~/.parachute/` instead of `~/Parachute/.parachute/`
- Write initial config to `~/.parachute/config.yaml`
- Migrate existing config if `~/Parachute/.parachute/config.yaml` exists
- Update PATH and daemon startup instructions

#### 5.4 `computer/sample-vault/`

- Keep as-is for tests and local dev (sample-vault is the development fallback)
- Update test fixtures to use `parachute_dir` instead of `vault_path`

---

## Technical Considerations

### Working Directory Path Convention

**Current:** Paths stored as `/vault/relative/path` in SQLite. `resolve_working_directory()` translates to real path.

**New:** Store absolute paths as-is (e.g., `/Users/parachute/Projects/foo`). Empty/None → `Path.home()`. Much simpler.

**Migration:** During SQLite → Kuzu migration, translate `/vault/...` stored paths to real absolute paths using the old vault root.

### LadybugDB Quirks (from memory)

- Use `description` not `desc` (reserved)
- Composite primary keys: use string concatenation `"{session_id}:{tag}"` for tag PK
- Multi-param SET in relationship queries: use f-strings with `_esc()` sanitization
- MERGE/MATCH with `$param` works reliably for node lookups

### Ordering

Phase 1 must come first (path infrastructure). Phase 2 depends on Phase 1 (needs `parachute_dir` for DB path). Phase 3 runs as part of Phase 2 server startup. Phases 4 and 5 are independent and can run in parallel with Phase 2.

### Backwards Compatibility

- Old `VAULT_PATH` env var: honor during transition with deprecation warning → maps to `parachute_dir` if it equals old vault pattern, otherwise ignored
- Old `~/Parachute/.parachute/config.yaml` bootstrap: handled in migration script
- Sessions stored with `/vault/...` working dirs: translated during SQLite migration

---

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| SQLite migration loses data | Test migration against real DB before shipping; keep SQLite file, don't delete it |
| Kuzu session queries slower than SQLite | Session list is indexed by `session_id`; acceptable for single-user local tool |
| LadybugDB quirks break session schema | Prototype and test Kuzu schema against real DB before full rewrite |
| Flutter macOS secure bookmarks | Home dir bookmark already works; no new user permission prompts expected |
| install.sh migration creates conflicts | Migration script is copy-not-move; old vault untouched |
| Tests using vault_path fixtures | Update test conftest.py to use parachute_dir; most tests use tmp_path anyway |

---

## References

- Brainstorm: `docs/brainstorms/2026-03-03-storage-restructure-vault-to-dotparachute-brainstorm.md`
- `computer/parachute/config.py` — Settings and vault path resolution
- `computer/parachute/server.py` — Server lifespan, path initialization
- `computer/parachute/db/database.py` — Full SQLite schema (tables: sessions, session_tags, session_contexts, container_envs, pairing_requests, chunks, index_manifest)
- `computer/parachute/db/graph.py` — GraphService, ensure_node_table/ensure_rel_table patterns
- `computer/parachute/core/session_manager.py` — SessionManager, /vault/ path convention
- `computer/parachute/core/sandbox.py` — SANDBOX_DATA_DIR, container mounts
- `app/lib/core/services/file_system_service.dart` — FileSystemService, macOS home path default
- `app/lib/features/vault/services/file_browser_service.dart` — isWithinVault, security checks
