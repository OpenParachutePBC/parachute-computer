---
title: "refactor: Dead Code Sweep & Terminology Cleanup"
type: refactor
date: 2026-02-09
brainstorm: docs/brainstorms/2026-02-09-dead-code-sweep-brainstorm.md
---

# refactor: Dead Code Sweep & Terminology Cleanup

## Overview

Remove ~2,100 lines of dead curator code from the Flutter app, complete the "Base" → "Computer" terminology migration in app code, rename doc page filenames, and remove the unused `bm25` dependency. All changes are mechanical refactoring with no behavior changes.

## Motivation

The server-side curator system was removed months ago, but the app still carries 5 dead files and references in 16+ others. The "Base" → "Computer" rename was done in the Python server but never in the Flutter app code or doc filenames. This creates confusion for contributors and adds maintenance burden.

## Atomic Groups & Ordering

The SpecFlow analysis identified critical ordering dependencies. Changes must be made in these atomic groups:

```
Group A (curator files)  ──┐
Group B (curator methods) ─┤──▶ Group C (rename curator_log) ──▶ Group D (rename BaseServer) ──▶ Group E (rename provider)
                           │
Group F (doc renames) ─────┘  (independent, separate repo)
Group G (bm25 removal) ───────  (independent, trivial)
```

**Rule:** `flutter analyze` must pass after each group. If it doesn't, fix before proceeding.

---

## Group A: Delete Dead Curator Files + Clean References

**Repo:** `app/`

### Critical ordering: Edit referencing files BEFORE deleting

#### A1. Edit `chat_service.dart`
- [x] Remove `part 'chat_curator_service.dart';` (line ~24)
- [x] Remove `import '../models/curator_session.dart';` (line ~13)

#### A2. Edit `chat_providers.dart` (barrel file)
- [x] Remove `export 'chat_curator_providers.dart';` (line ~39)
- [x] Remove associated comment (line ~15)

#### A3. Edit `chat_screen.dart`
- [x] Remove `import '...curator_session_viewer_sheet.dart';` (line ~21)
- [x] Remove `_showCuratorSheet` method and the `if (showCuratorFeatures ...)` button block that calls it
- [x] Note: the `base_server_provider.dart show showCuratorFeatures` import will be handled in Group B

#### A4. Edit `chat_server_import_service.dart`
- [x] Remove `getRecentCuratorActivity()` method (dead — hits removed `/api/curator/activity/recent`)
- [x] Remove `CuratorActivityInfo` and `CuratorUpdate` model classes
- [x] **KEEP** `curateClaudeExport()`, `CurateExportResult`, `getContextFilesInfo()`, `ContextFilesInfo` — these are LIVE (hit `/api/import/curate` and `/api/import/contexts`)

#### A5. Delete the 4 dead files
- [x] Delete `features/chat/models/curator_session.dart` (361 lines)
- [x] Delete `features/chat/widgets/curator_session_viewer_sheet.dart` (1,042 lines)
- [x] Delete `features/chat/providers/chat_curator_providers.dart` (87 lines)
- [x] Delete `features/chat/services/chat_curator_service.dart` (109 lines)

#### A6. Clean string references in Daily models
- [x] `agent_output.dart` — update "curator" in description strings to "agent"
- [x] `reflection.dart` — update "AI curator" strings to "daily agent"
- [x] `local_agent_config_service.dart` — update comment about "curator.md" filename

#### A7. Verify
- [x] Run `flutter analyze` — must pass with zero errors

---

## Group B: Remove Curator Code from BaseServerService + Provider

**Repo:** `app/`

#### B1. Edit `base_server_service.dart`
- [x] Remove `getDailyCuratorStatus()` method (~line 138)
- [x] Remove `triggerDailyCurator()` method (~line 164)
- [x] Remove `getCuratorTranscript()` method (~line 201)
- [x] Remove `DailyCuratorStatus` class (~line 381)
- [x] Remove `CuratorRunResult` class (~line 422)
- [x] **KEEP** `CuratorTranscript`, `TranscriptMessage`, `TranscriptBlock` — these are shared with the live `getAgentTranscript()` method. Rename to `AgentTranscript`, keeping the same fields.
- [x] Update `getAgentTranscript()` return type from `CuratorTranscript` to `AgentTranscript`

#### B2. Edit `base_server_provider.dart`
- [x] Remove `showCuratorFeatures` constant
- [x] Remove `dailyCuratorStatusProvider`
- [x] Remove `CuratorTriggerNotifier` class
- [x] Remove `curatorTriggerProvider`

#### B3. Edit `chat_screen.dart` (second pass)
- [x] Remove `import '...base_server_provider.dart' show showCuratorFeatures;` (line ~22)
- [x] Remove any remaining conditional blocks that checked `showCuratorFeatures`

#### B4. Edit `curator_log_screen.dart` (prep for Group C rename)
- [x] Remove the dead fallback branch that calls `getCuratorTranscript()` (~line 70)
- [x] Make `agentName` parameter required (non-nullable) since the fallback is gone
- [x] Update `CuratorTranscript` references to `AgentTranscript`

#### B5. Update `agent_trigger_card.dart`
- [x] Update any `CuratorTranscript` → `AgentTranscript` references if present (none found)

#### B6. Verify
- [x] Run `flutter analyze` — must pass

---

## Group C: Rename curator_log_screen → agent_log_screen

**Repo:** `app/`

#### C1. Rename file
- [x] `features/daily/journal/screens/curator_log_screen.dart` → `agent_log_screen.dart`

#### C2. Rename class + state
- [x] `CuratorLogScreen` → `AgentLogScreen`
- [x] `_CuratorLogScreenState` → `_AgentLogScreenState`

#### C3. Update internal strings
- [x] debugPrint tags: `[CuratorLogScreen]` → `[AgentLogScreen]`
- [x] UI title fallback: `'Curator Log'` → `'Agent Log'`

#### C4. Update importing files
- [x] `features/settings/widgets/daily_agents_section.dart` — update import path, constructor call, and comment
- [x] `features/daily/journal/widgets/agent_output_header.dart` — update import path and constructor call

#### C5. Verify
- [x] Run `flutter analyze` — must pass

---

## Group D: Rename BaseServerService → ComputerServerService

**Repo:** `app/`

#### D1. Rename file
- [x] `core/services/base_server_service.dart` → `computer_server_service.dart`

#### D2. Rename class internals
- [x] `BaseServerService` → `ComputerServerService`
- [x] `BaseServerService._internal` → `ComputerServerService._internal`
- [x] Factory constructor name
- [x] `static final BaseServerService _instance` → `static final ComputerServerService _instance`

#### D3. Update all import sites (both package and relative paths)
- [x] `core/providers/app_state_provider.dart` — uses relative path `../services/base_server_service.dart`
- [x] `core/providers/base_server_provider.dart` (renamed in Group E)
- [x] `features/daily/journal/widgets/agent_trigger_card.dart` — package path
- [x] `features/daily/journal/providers/journal_providers.dart` — package path
- [x] `features/daily/journal/screens/agent_log_screen.dart` — package path
- [x] `features/settings/widgets/computer_setup_wizard.dart` — package path
- [x] Note: `chat_screen.dart` did not import base_server_service directly

#### D4. Update all constructor call sites
- [x] `app_state_provider.dart`: `BaseServerService()` → `ComputerServerService()`
- [x] `agent_trigger_card.dart`: same
- [x] `journal_providers.dart`: same
- [x] `computer_setup_wizard.dart`: same

#### D5. Update doc comment reference
- [x] `sync_service.dart`: "Follows the same pattern as BaseServerService" → "ComputerServerService"

#### D6. Verify
- [x] Run `flutter analyze` — must pass

---

## Group E: Rename base_server_provider → computer_server_provider

**Repo:** `app/`

#### E1. Rename file
- [x] `core/providers/base_server_provider.dart` → `computer_server_provider.dart`

#### E2. Rename provider names
- [x] `baseServerServiceProvider` → `computerServerServiceProvider`

#### E3. Update all import sites
- [x] `features/daily/journal/screens/agent_log_screen.dart`
- [x] `features/daily/journal/widgets/agent_trigger_card.dart`
- [x] Note: other files used `ComputerServerService()` directly, not the provider

#### E4. Verify
- [x] Run `flutter analyze` — must pass

---

## Group F: Rename Doc Page Filenames

**Repo:** `openparachute.io/`

#### F1. Rename 6 HTML files
- [x] `base-overview.html` → `computer-overview.html`
- [x] `base-api.html` → `computer-api.html`
- [x] `base-orchestrator.html` → `computer-orchestrator.html`
- [x] `base-agents.html` → `computer-agents.html`
- [x] `base-database.html` → `computer-database.html`
- [x] `base-connectors.html` → `computer-connectors.html`

#### F2. Update all cross-links (~142 occurrences across 18 files)
- [x] Update sidebar navigation in ALL doc pages (every page has 6 links to these files)
- [x] Update nav card links in footer sections
- [x] Update `AUDIT-FINDINGS.md` references

#### F3. Verify
- [x] Grep for any remaining `base-overview`, `base-api`, `base-orchestrator`, `base-agents`, `base-database`, `base-connectors` references — 0 found

---

## Group G: Remove Unused bm25 Dependency

**Repo:** `app/`

#### G1. Edit `pubspec.yaml`
- [x] Remove `bm25: ^1.0.0` line (~line 98)
- [x] Remove associated comment `# BM25 keyword search for local RAG` (~line 97)

#### G2. Regenerate lock file
- [x] Run `flutter pub get` to update `pubspec.lock`

---

## Group H: Update CLAUDE.md

**Repo:** `app/`

#### H1. Edit `app/CLAUDE.md`
- [x] Update architecture diagram: `Base Server` → `Parachute Computer` in the communication flow
- [x] Verify no other stale "Base" references

---

## Acceptance Criteria

- [x] `flutter analyze` passes with zero errors
- [x] No references to "curator" remain in app code (except "curate" in the live import curation feature)
- [x] No references to "BaseServerService" or "base_server_service" remain
- [x] No references to "base_server_provider" remain
- [x] All doc page links work after filename renames
- [ ] `flutter build macos` succeeds (not tested yet)
- [x] `bm25` removed from pubspec.yaml and pubspec.lock

## Dependencies & Risks

**Risk: Partial completion leaves app uncompilable.** Each group is atomic — all steps within a group must complete together. Commit after each group passes `flutter analyze`.

**Risk: "curate" vs "curator" confusion.** `curateClaudeExport()` and `CurateExportResult` in `chat_server_import_service.dart` are LIVE features for Claude Code export curation. Do NOT delete these. Only delete methods hitting removed `/api/curator/*` endpoints.

**Risk: Shared model classes.** `CuratorTranscript`, `TranscriptMessage`, `TranscriptBlock` are used by the live `getAgentTranscript()` method. Rename to `AgentTranscript` but do not delete.

**Risk: Two git repos.** App changes go in `app/`, doc renames go in `openparachute.io/`. These require separate commits.

## Files Modified

### app/ (Dart)
| Action | File | Lines removed |
|--------|------|---------------|
| Delete | `features/chat/models/curator_session.dart` | 361 |
| Delete | `features/chat/widgets/curator_session_viewer_sheet.dart` | 1,042 |
| Delete | `features/chat/providers/chat_curator_providers.dart` | 87 |
| Delete | `features/chat/services/chat_curator_service.dart` | 109 |
| Rename | `daily/journal/screens/curator_log_screen.dart` → `agent_log_screen.dart` | — |
| Rename | `core/services/base_server_service.dart` → `computer_server_service.dart` | — |
| Rename | `core/providers/base_server_provider.dart` → `computer_server_provider.dart` | — |
| Edit | `chat_service.dart`, `chat_providers.dart`, `chat_screen.dart` | ~30 |
| Edit | `chat_server_import_service.dart` | ~50 |
| Edit | `base_server_service.dart` (curator methods + rename) | ~120 |
| Edit | `base_server_provider.dart` (curator providers + rename) | ~40 |
| Edit | ~10 files updating imports | — |
| Edit | `pubspec.yaml` | 2 |
| Edit | `CLAUDE.md` | 1 |

**Estimated net reduction:** ~1,800 lines removed

### openparachute.io/ (HTML)
| Action | Files |
|--------|-------|
| Rename | 6 HTML files (base-*.html → computer-*.html) |
| Edit | 18 files updating cross-links (~142 occurrences) |

## References

- Brainstorm: `docs/brainstorms/2026-02-09-dead-code-sweep-brainstorm.md`
- Audit findings: `openparachute.io/docs/AUDIT-FINDINGS.md`
- App conventions: `app/CLAUDE.md`
