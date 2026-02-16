---
title: "Dead Code Sweep & Terminology Cleanup"
type: refactor
date: 2026-02-16
issue: 30
modules: [computer, app]
priority: P2
deepened: 2026-02-16
---

# Dead Code Sweep & Terminology Cleanup

## Enhancement Summary

**Deepened on:** 2026-02-16
**Sections enhanced:** All 3 phases
**Review agents used:** code-simplicity-reviewer, flutter-reviewer, python-reviewer, parachute-conventions-reviewer, architecture-strategist, pattern-recognition-specialist

### Key Improvements from Deepening
1. Phase 2 scope expanded — discovered ~200 lines of dead curator code in `chat_server_import_service.dart` missing from original plan
2. `contextFilesInfoProvider` confirmed to have zero consumers — delete, don't relocate
3. Consumer list for Phase 3 corrected from "13+" to actual 6 importing files (plus UI string files)
4. `context/curator.md` vault path in `daily_agent.py` identified as functional code requiring careful handling
5. Infrastructure files (`lima/parachute.yaml`, `scripts/build_computer_dmg.sh`) added to Phase 3 scope
6. `debugPrint` tag updates added to Phase 3 scope

### New Considerations Discovered
- `chat_providers.dart` barrel file re-exports `chat_curator_providers.dart` — must remove export line
- `getCuratorTranscript()` method may be dead (legacy null-agentName path) — verify during implementation
- `BackendHealthService` naming inconsistency with `ComputerService` — file as follow-up, not in scope
- Substantial legacy debt beyond curator/base-server exists — out of scope but noted for future issue

---

## Overview

Remove deprecated "curator" code that has been fully disabled, rename "Base Server" terminology to "Parachute Computer" for consistency with the monorepo naming.

**Scope**: ~25 files across `app/` and `computer/`. Three phases executed in dependency order.

## Problem Statement

The codebase carries significant dead weight from the removed curator feature (disabled behind `showCuratorFeatures = false`, server endpoints already removed) and inconsistent "Base Server" naming that doesn't match the project's identity as "Parachute Computer". This confuses contributors and makes the codebase harder to search.

## Proposed Solution

Three phases, executed in order. Each phase is one atomic commit.

---

## Phase 1: Dead Code Removal

**Goal**: Delete all commented-out code and `CURATOR REMOVED` marker comments from the Python server. Zero functional impact.

### Server (`computer/`)

| File | Action |
|------|--------|
| `parachute/api/__init__.py:7,30` | Delete `CURATOR REMOVED` comment lines |
| `parachute/api/imports.py:15-16,323-325` | Delete `CURATOR REMOVED` comment blocks |
| `parachute/api/scheduler.py:59-61` | Delete `DAILY_AGENT REMOVED` comment block |
| `parachute/server.py:32,84,175` | Delete `CURATOR REMOVED` comment lines |
| `parachute/db/database.py:95-125` | Delete commented-out `curator_sessions` and `curator_queue` table definitions |
| `parachute/db/database.py:197-209` | Delete commented-out migration for `tool_calls` column |
| `parachute/core/orchestrator.py:1118-1127` | Delete `CURATOR REMOVED` disabled block |
| `parachute/core/orchestrator.py:1722-1760` | Delete commented-out `_queue_curator_task` method |

### Research Insights

**DB tables are purely inert comments**: The commented-out `curator_sessions` and `curator_queue` CREATE TABLE statements use SQL `--` prefixes inside the `SCHEMA_SQL` string — `executescript()` skips them. The commented migration uses Python `#` prefixes. Neither participates in migration logic. Safe to delete.

**Existing databases may still have physical curator tables**: SQLite handles unused tables gracefully, so no DROP TABLE migration is needed. Optionally file a follow-up to clean these up.

**No Python tests reference curator**: Zero matches in `computer/tests/`, confirming no test regression risk.

### Acceptance Criteria

- [x] No `CURATOR REMOVED` or `DAILY_AGENT REMOVED` comments remain in `computer/`
- [x] No commented-out DB table definitions remain in `database.py`
- [x] No commented-out methods remain in `orchestrator.py`
- [x] Server starts successfully: `parachute server -f`
- [x] `curl http://localhost:3333/api/health` returns OK

---

## Phase 2: Curator Terminology Cleanup

**Goal**: Remove dead curator UI code from the Flutter app, rename live classes that were misnamed "curator" but actually serve all daily agents, clean up server docstrings.

### Delete Dead Files (app/)

| File | Reason |
|------|--------|
| `lib/features/chat/services/chat_curator_service.dart` | `part of` extension calling removed server endpoints. Also remove `part 'chat_curator_service.dart';` from `chat_service.dart:29` and `import '../models/curator_session.dart'` from `chat_service.dart:13` |
| `lib/features/chat/models/curator_session.dart` | Model for removed curator feature |
| `lib/features/chat/widgets/curator_session_viewer_sheet.dart` | UI for removed curator feature |
| `lib/features/chat/providers/chat_curator_providers.dart` | **ALL 5 providers are dead** (zero consumers outside deleted files). Delete entire file. Also remove re-export from `chat_providers.dart:39` |

### Delete Dead Code From Live Files (app/)

| File | What to Delete |
|------|---------------|
| `lib/core/providers/base_server_provider.dart` | Delete: `showCuratorFeatures` flag (line 5), `dailyCuratorStatusProvider` (line 20), `CuratorTriggerNotifier` class (line 32), `curatorTriggerProvider` (line 58) |
| `lib/core/services/base_server_service.dart` | Delete: `DailyCuratorStatus` class, `CuratorRunResult` class, `getDailyCuratorStatus()` method, `triggerDailyCurator()` method |
| `lib/features/chat/services/chat_server_import_service.dart` | Delete ~200 lines of dead curator code: `curateClaudeExport()` method (lines 49-69), `getContextFilesInfo()` method (lines 76-93), `getRecentCuratorActivity()` method (lines 99-116), `CurateExportResult` model (lines 209-249), `ContextFilesInfo` model (lines 252-273), `ContextFileMetadata` model (lines 276-310), `CuratorActivityInfo` model (lines 314-342), `CuratorUpdate` model (lines 345-379) |

### Rename Live "Curator" Classes (app/)

These classes are named "curator" but serve ALL daily agents — rename, don't delete:

| Current | New | Files Affected |
|---------|-----|---------------|
| `CuratorTranscript` | `AgentTranscript` | `base_server_service.dart` + `curator_log_screen.dart` |
| `TranscriptMessage` | Keep as-is (generic) | — |
| `TranscriptBlock` | Keep as-is (generic) | — |
| `curator_log_screen.dart` | `agent_log_screen.dart` | File rename + update imports in `agent_output_header.dart:8`, `daily_agents_section.dart:8` |
| `CuratorLogScreen` class | `AgentLogScreen` | Same 3 files |

**Verify during implementation**: The `getCuratorTranscript()` method in `base_server_service.dart` serves the `agentName == null` fallback path in the log screen. Check if any code calls the screen without an `agentName`. If not, delete `getCuratorTranscript()` as dead code and keep only `getAgentTranscript()`.

### Server Cleanup (computer/)

| File | Action |
|------|--------|
| `core/daily_agent_tools.py:264-384` | Delete `create_curator_tools` compatibility wrapper (confirmed zero callers) |
| `core/context_folders.py:8` | Update docstring: remove "curator" reference |
| `core/daily_agent.py:128` | Update comment example: "curator.md" → "content-scout.md" |
| `core/daily_agent.py:234-238` | **CAREFUL**: `load_user_context()` tries `vault_path / "context" / "curator.md"` as a functional fallback path. Keep this path as-is for backward compatibility with existing user vaults. Add a comment: `# Legacy path — kept for users with existing context/curator.md files` |
| `core/daily_agent.py:271` | Update docstring example: "curator" → "content-scout" |
| `core/chat_log.py:258-260,308` | Update docstrings: "curator" → "daily agent" |
| `core/session_manager.py:494,560,934` | Update comments: "curator sessions" → "agent sessions" |

### Research Insights

**`create_curator_tools` has zero callers**: Grep confirmed the function definition is the only reference. Safe to delete.

**`context/curator.md` is a vault file path**: Line 236 of `daily_agent.py` tries to read this file from user vaults. Some users may have this file for personalization. Removing it silently would break user context loading. Keep as a legacy fallback with a clarifying comment.

**No `.g.dart` codegen files exist**: The project uses hand-written Riverpod providers, not `riverpod_generator`. No generated code will break.

**No test references to curator**: Both `app/test/` and `app/integration_test/` have zero curator references.

### Acceptance Criteria

- [x] Zero references to "curator" remain in `app/` (except git history)
- [x] `flutter analyze` passes with no errors
- [x] Daily agent transcript viewing still works (renamed, not removed)
- [x] Settings > Daily Agents section still shows agent logs correctly
- [x] Server starts and daily agent features work
- [x] `grep -ri "curator" app/lib/` returns zero results
- [x] `chat_providers.dart` no longer re-exports deleted file

---

## Phase 3: "Base Server" → "Parachute Computer" Rename

**Goal**: Rename `BaseServerService` and related terminology to match the project's identity.

### Research Insights

**"ComputerService" is the right name**: Follows the existing pattern of short, direct service names (`ChatService`, `BrainService`, `SyncService`). Using `ParachuteComputerService` would be unnecessarily verbose and break convention.

**SharedPreferences keys must be preserved**: The keys `parachute_server_url` and the API key are persisted in user data. Changing them would force reconfiguration. Keep the private `_serverUrlKey` and `_apiKeyKey` constants as-is.

**Filesystem paths must be preserved**: `~/Library/Application Support/Parachute/base` is a real directory on user machines. The code-level rename changes class/method names only, not the actual path string.

### Class & File Renames (app/)

| Current | New |
|---------|-----|
| `BaseServerService` class | `ComputerService` |
| `base_server_service.dart` | `computer_service.dart` |
| `base_server_provider.dart` | `computer_provider.dart` |
| `baseServerServiceProvider` | `computerServiceProvider` |
| `baseServerPathProvider` | `computerPathProvider` |

### Consumer Files to Update (6 files with direct imports)

| File | Change |
|------|--------|
| `core/providers/computer_provider.dart` | Self — already renamed |
| `core/providers/app_state_provider.dart` | Update import + `customBaseServerPathProvider` → `customComputerPathProvider` |
| `features/settings/widgets/computer_setup_wizard.dart` | Update import + references |
| `features/daily/journal/providers/journal_providers.dart` | Update import + references |
| `features/daily/journal/widgets/agent_trigger_card.dart` | Update import + references |
| `features/daily/journal/screens/agent_log_screen.dart` | Update import + references |

### Files with Indirect References (no import change, but string/method updates)

| File | Change |
|------|--------|
| `core/services/backend_health_service.dart` | Update error string: "Parachute Base server" → "Parachute Computer" |
| `core/services/lima_vm_service.dart` | Rename methods: `isBaseServerInstalled()` → `isComputerInstalled()`, `installBaseServer()` → `installComputer()`, `updateBaseServer()` → `updateComputer()`, `baseServerPath` → `computerPath` (keep actual `base` dir). Update ~10 comments and debug strings. |
| `core/services/bare_metal_server_service.dart` | Same method renames as lima_vm_service. Update ~10 comments and debug strings. |
| `features/settings/widgets/server_settings_section.dart` | Update UI strings |
| `features/chat/screens/chat_hub_screen.dart` | Update UI strings |
| `features/onboarding/widgets/server_connection_step.dart` | Update UI strings |
| `core/services/sync_service.dart` | Update comment referencing "BaseServerService" pattern |
| `features/settings/widgets/sync_settings_section.dart` | Update UI string: "Parachute Base server" → "Parachute Computer" |

### UI String Updates

| File | Old Text | New Text |
|------|----------|----------|
| `server_connection_step.dart` | "Connect to a Parachute Base server" | "Connect to Parachute Computer" |
| `chat_hub_screen.dart:467` | "Configure a Parachute Base server" | "Configure Parachute Computer" |
| `chat_hub_screen.dart:659` | "Make sure Parachute Base is running" | "Make sure Parachute Computer is running" |
| `server_settings_section.dart` | "Parachute Base Server" (heading + others) | "Parachute Computer" |
| `backend_health_service.dart:47` | "The Parachute Base server is not responding" | "Parachute Computer is not responding" |
| `agent_trigger_card.dart` | "Start the Parachute Base server" | "Start Parachute Computer" |
| `sync_settings_section.dart` | "Parachute Base server" | "Parachute Computer" |
| `computer/__init__.py:2` | "Parachute Base Server" | "Parachute Computer" |

### debugPrint Tag Updates

Update all `debugPrint('[BaseServerService]...')` calls in `computer_service.dart` (formerly `base_server_service.dart`) to `debugPrint('[ComputerService]...')`. There are ~20 occurrences.

### Infrastructure Files

| File | Change |
|------|--------|
| `app/lima/parachute.yaml` | Update comments: "base server" → "Parachute Computer" (lines 38, 142, 152) |
| `app/scripts/build_computer_dmg.sh` | Update comments: "base server" → "Parachute Computer" (lines 7, 104, 106, 115, 122) |

### Properties to Rename

| File | Old | New | Note |
|------|-----|-----|------|
| `lima_vm_service.dart` | `baseServerPath` | `computerPath` | Keep actual `base` dir on disk |
| `bare_metal_server_service.dart` | `baseServerPath` | `computerPath` | Keep actual `base` dir on disk |
| `lima_vm_service.dart` | `isBaseServerInstalled()` | `isComputerInstalled()` | |
| `lima_vm_service.dart` | `installBaseServer()` | `installComputer()` | |
| `lima_vm_service.dart` | `updateBaseServer()` | `updateComputer()` | |
| `bare_metal_server_service.dart` | `isBaseServerInstalled()` | `isComputerInstalled()` | |
| `bare_metal_server_service.dart` | `installBaseServer()` | `installComputer()` | |
| `bare_metal_server_service.dart` | `updateBaseServer()` | `updateComputer()` | |
| `app_state_provider.dart` | `customBaseServerPathProvider` | `customComputerPathProvider` | |

### Verification Strategy

After all changes, run a final sweep:
```bash
grep -ri "base.server\|BaseServer\|base_server" app/lib/ --include="*.dart"
grep -ri "Parachute Base" app/ --include="*.dart" --include="*.yaml" --include="*.sh"
```

Only expected survivors: SharedPreferences key string `'parachute_server_url'` and filesystem path strings containing `/base`.

### Acceptance Criteria

- [x] Zero references to "BaseServer" or "base_server" in `app/lib/` (except SharedPreferences keys and filesystem paths)
- [x] Zero "Parachute Base" strings in UI-facing code
- [x] `flutter analyze` passes with no errors
- [x] App connects to server successfully after rename
- [x] Onboarding flow shows "Parachute Computer" text
- [x] Settings shows "Parachute Computer" heading
- [x] Existing user configurations are preserved (SharedPreferences keys unchanged)
- [x] `debugPrint` tags updated to `[ComputerService]`

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Breaking existing user server URL config | Keep SharedPreferences key `parachute_server_url` unchanged |
| Breaking filesystem paths | Keep actual `base` directory name on disk |
| Removing live code mistaken for dead | `CuratorTranscript` is live (renamed, not deleted); `curator_log_screen.dart` is live (renamed) |
| Import breakage from file renames | Run `flutter analyze` after each phase; fix all errors before committing |
| Breaking user vault personalization | Keep `context/curator.md` fallback path in `daily_agent.py` with legacy comment |
| Missing dead code in chat_server_import_service | Added ~200 lines of dead curator models/methods to Phase 2 scope |

## Execution Order

```
Phase 1 (dead comments/code)  →  Phase 2 (curator cleanup)  →  Phase 3 (BaseServer rename)
         lowest risk                    medium risk                    highest risk
```

Each phase is one commit. Run `flutter analyze` and server startup check between phases.

## Out of Scope (Follow-Up Issues)

- **Split `computer_service.dart`**: At ~700 lines, the file does too much (HTTP client + models + daily agent methods). Consider extracting model classes to `models/daily_agent.dart` in a future PR.
- **Rename `BackendHealthService` → `ComputerHealthService`**: Creates vocabulary inconsistency with `ComputerService`, but is a separate rename not required for this cleanup.
- **Drop physical `curator_sessions`/`curator_queue` tables**: Existing SQLite databases may have these tables. A future migration could DROP them, but SQLite handles unused tables gracefully.
- **Broader legacy debt audit**: `FileSystemService` has deprecated factories, `AppColors`/`TypographyTokens` are deprecated, `live_transcription_service_v3.dart` is a legacy re-export. File a separate issue.

## References

- Issue: #30
- `app/lib/core/services/base_server_service.dart` — primary file for Phase 3
- `app/lib/core/providers/base_server_provider.dart` — curator flags + base server provider
- `app/lib/features/chat/services/chat_server_import_service.dart` — dead curator code discovered by deepening
- `computer/parachute/db/database.py` — commented-out curator tables
- `computer/parachute/core/orchestrator.py` — commented-out curator integration
- `computer/parachute/core/daily_agent.py:236` — functional `context/curator.md` vault path
