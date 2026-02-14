---
topic: Dead Code Sweep & Terminology Cleanup
date: 2026-02-09
status: decided
participants: Aaron, Claude
---

# Dead Code Sweep & Terminology Cleanup

## What We're Building

A comprehensive cleanup pass across the app and docs to remove dead code left behind by the curator system removal, complete the "Base" → "Computer" terminology migration, and eliminate unused stubs and dependencies.

## Why This Approach

The docs audit revealed 17 files in the Flutter app still referencing a curator system that no longer exists on the server side. Additionally, the "Base" → "Computer" rename was done in the server codebase but never completed in the app or doc filenames. Cleaning this up now:

- **Reduces confusion** for new contributors seeing dead imports and stale class names
- **Shrinks the codebase** by ~1,700+ lines of truly dead code
- **Completes a migration** that was left half-done (Base → Computer)
- **Removes risk** before adding new features on top of stale foundations

## Key Decisions

1. **Delete, don't deprecate** — The 4 fully dead curator files should be deleted outright, not commented or flagged. The server-side code they depended on is gone.

2. **Rename curator_log_screen → agent_log_screen** — It's functional but misnamed. Since we're already touching curator references, do it now.

3. **Rename BaseServerService → ComputerServerService** — Mechanical rename (~10-15 files) that completes the terminology migration in app code.

4. **Rename doc filenames** — `base-*.html` → `computer-*.html` for all 6 server doc pages, updating all cross-links.

5. **Full sweep** — Also delete vision stubs and verify/remove unused pubspec dependencies.

## Scope

### 1. Delete Dead Curator Files (app/)

| File | Lines | Why dead |
|------|-------|----------|
| `features/chat/models/curator_session.dart` | 361 | Model for server-side curator that no longer exists |
| `features/chat/widgets/curator_session_viewer_sheet.dart` | 1,042 | UI for viewing curator sessions — no data source |
| `features/chat/providers/chat_curator_providers.dart` | ~150 | Providers for curator data — no endpoints to call |
| `features/chat/services/chat_curator_service.dart` | ~200 | Service calling curator API — endpoints removed |

### 2. Clean Curator References (~13 files)

Remove imports, method calls, and provider references that touched the deleted files:
- `chat_screen.dart` — remove CuratorSession import and usage
- `chat_service.dart` — remove curator-related methods
- `chat_providers.dart` — remove curator provider references
- `chat_server_import_service.dart` — remove curator import logic
- `agent_output_header.dart` — update curator terminology to "agent"
- Daily models (`agent_output.dart`, `reflection.dart`) — update curator string references

### 3. Rename curator_log_screen → agent_log_screen

- Rename file: `curator_log_screen.dart` → `agent_log_screen.dart`
- Rename class: `CuratorLogScreen` → `AgentLogScreen`
- Update all imports and route references

### 4. Rename BaseServerService → ComputerServerService

- `base_server_service.dart` → `computer_server_service.dart`
- `base_server_provider.dart` → `computer_server_provider.dart`
- `BaseServerService` → `ComputerServerService`
- `baseServerProvider` → `computerServerProvider`
- Update all imports across the app

### 5. Rename Doc Filenames

| Old | New |
|-----|-----|
| `base-overview.html` | `computer-overview.html` |
| `base-api.html` | `computer-api.html` |
| `base-orchestrator.html` | `computer-orchestrator.html` |
| `base-agents.html` | `computer-agents.html` |
| `base-database.html` | `computer-database.html` |
| `base-connectors.html` | `computer-connectors.html` |

Update all cross-links in all 16+ doc pages' sidebars and nav cards.

### 6. Delete Vision Service Stubs

Remove stub files in `app/lib/core/services/vision/` that contain only placeholder implementations.

### 7. Remove Unused Dependencies

Verify and remove from `pubspec.yaml`:
- `dio` — if no longer imported anywhere
- `bm25` — if no longer imported anywhere
- `go_router` — if no longer imported anywhere

## Open Questions

- None — scope is well-defined and mechanical.

## Risks

- **Rename churn** — Lots of import path changes. Mitigate by running `flutter analyze` after each rename step.
- **Hidden references** — Some curator references may be in strings or comments. Grep thoroughly.
- **pubspec dependencies** — Need to verify each dependency is truly unused before removing. `flutter pub deps --no-dev` can help.

## Success Criteria

- `flutter analyze` passes with no errors
- No references to "curator" remain in app code (except possibly in git history)
- No references to "BaseServer" or "base_server" remain in app code
- All doc page links work after filename renames
- App builds and runs on macOS without regression
