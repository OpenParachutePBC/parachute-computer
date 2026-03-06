---
date: 2026-03-03
topic: storage-restructure-vault-to-dotparachute
status: brainstorm
priority: P1
labels: computer, brain, chat, daily
issue: "#170"
---

# Storage Restructure: Vault → ~/.parachute

## What We're Building

Parachute was originally designed as a file-based second brain (like Obsidian), with `~/Parachute` as a user-facing vault. That model no longer matches reality: Brain, Daily, and soon Chat all store data in the Kuzu graph database, not in plain files. The vault concept is causing unnecessary friction — it isolates users from their own filesystem and forces a special-purpose directory structure on them.

This work removes the vault abstraction. System data moves to `~/.parachute/` (a standard hidden dot-directory, invisible by default, accessible to power users). The user's regular home directory becomes the natural navigation root. Sessions no longer have a fixed "vault scope" — they reference whatever directories are relevant to the work at hand.

## Why This Approach

We considered three paths:

**A. Keep vault, rename it** — Rename `~/Parachute` to `~/.parachute`. Simplest path, but doesn't solve the real problem: users are still fenced off from their filesystem, and the directory still conflates user data with system internals.

**B. Split vault into system + home (chosen)** — Move all system internals to `~/.parachute/`. Remove the vault concept entirely. Sessions access `~/` by default with per-session context. This matches how every other tool on macOS works (databases in `~/Library/`, configs in hidden dirs).

**C. Full Kuzu-only migration first** — Migrate everything (including SQLite session metadata) to Kuzu before restructuring paths. Tempting for purity, but the path restructure and DB migration are separable concerns.

We're doing **B + the SQLite→Kuzu migration** together, since SQLite is the last thing keeping `Chat/sessions.db` alive.

## Key Decisions

- **`vault_path` concept removed**: No more configurable vault root. The server knows `~/.parachute/` is its home and `~/` is the user's home. These are derived from `os.path.expanduser()`, not config.
- **`~/.parachute/` is the new system directory**: Holds all configs, the graph DB, session transcripts, sandbox homes, modules, skills, MCPs, and logs.
- **SQLite → Kuzu for session metadata**: `Chat/sessions.db` is the last SQLite dependency. Session metadata (sessions, tags, contexts, containers, pairing requests) migrates into the Kuzu graph.
- **Per-session file context**: No fixed vault scope. Sessions reference working directories explicitly. Default file navigation opens from `~/`.
- **Docker containers**: Existing containers mount the vault read-only. New behavior TBD in planning — likely mount specific user-selected directories per session, or a configurable set of paths.

## New `~/.parachute/` Structure

```
~/.parachute/
├── config.yaml            # Server config (port, log_level, auth_mode, model)
├── .token                 # Claude OAuth token (0600)
├── module_hashes.json     # Module approval hashes
├── plugin-manifests/      # Installed plugin metadata
├── agents/                # Custom SDK agents
├── skills/                # Custom skills (.md files)
├── mcp.json               # MCP server configurations
├── CLAUDE.md              # Optional server instructions
├── logs/                  # Daemon logs
├── graph/
│   └── parachute.kz       # Unified Kuzu graph DB (Brain + Daily + Chat sessions)
├── sessions/              # SDK JSONL transcripts (was ~/Parachute/.claude/)
├── sandbox/
│   └── envs/              # Per-container persistent home directories
└── modules/               # Installed vault modules (was ~/Parachute/.modules/)
```

What disappears:
- `~/Parachute/Chat/sessions.db` → migrated to Kuzu
- `~/Parachute/Daily/` → already in graph; directory goes away
- `~/Parachute/Brain/` → already in graph; directory goes away
- `~/Parachute/.brain/brain.lbug` → moves to `~/.parachute/graph/parachute.kz`
- `~/Parachute/.parachute/` → moves to `~/.parachute/`
- `~/Parachute/.claude/` → moves to `~/.parachute/sessions/`
- `~/Parachute/.modules/` → moves to `~/.parachute/modules/`

## Migration Plan (High Level)

1. **Confirm Kuzu schema** for sessions: `Parachute_Session`, `Session_Tag`, `Session_Context`, `Container_Env`, `Pairing_Request`
2. **Write migration script** that reads SQLite and writes to Kuzu — one-time, run on server start if `~/.parachute/` doesn't exist yet
3. **Copy existing data** from `~/Parachute/.parachute/` to `~/.parachute/` (config, token, module hashes, agents, skills, logs)
4. **Move graph DB** from `~/Parachute/.brain/brain.lbug` to `~/.parachute/graph/parachute.kz`
5. **Move JSONL transcripts** from `~/Parachute/.claude/` to `~/.parachute/sessions/`
6. **Update all path references** in `config.py`, `server.py`, `session_manager.py`, `sandbox.py`, `graph.py`
7. **Remove `vault_path`** from config and server settings
8. **Update permission scoping** — drop vault-scoped path validation; sessions have no fixed root

## Open Questions

- **Docker container mounts**: Containers currently mount `~/Parachute` read-only at `/home/sandbox/Parachute`. With no vault, what do sandboxed sessions see? Options: mount `~/` read-only, mount nothing by default (user adds context explicitly), or mount a configurable list of paths.
- **Existing `~/Parachute/` cleanup**: Should we automatically archive/remove the old vault dir after migration, or leave it for the user?
- **Config bootstrap**: Config currently bootstraps from `~/Parachute/.parachute/config.yaml`. New boot sequence needs to check `~/.parachute/config.yaml` first (plus env var override).
- **Flutter app paths**: The app currently sends vault-relative paths. Need to audit what the Flutter app references and update accordingly.

## Next Steps

→ `/plan` for implementation details
