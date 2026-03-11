---
title: "Caller Management UI"
type: feat
date: 2026-03-11
issue: 221
---

# Caller Management UI

Transform the existing settings-buried Caller list into a first-class management experience accessible from the journal screen.

## Problem

Callers are only discoverable inside Settings → Daily Agents. The empty state on today's journal links to `/settings` — a generic destination that doesn't guide users to Caller configuration. There's no way to toggle a Caller on/off, adjust its schedule, or see what it produces without digging through settings.

## Proposed Solution

Promote Caller management to its own screen (`CallerManagementScreen`) reachable in one tap from the journal. Refactor the existing `DailyAgentsSection` into a proper screen with enable/disable toggles, inline schedule editing, and a detail bottom sheet for each Caller.

**Scope deliberately narrow**: This plan addresses the UI management layer only. It does not add new Callers, a "library" browser, or Caller authoring. Those are future work once the management surface exists.

## Acceptance Criteria

- [ ] "Manage Callers" entry point visible from journal header (replaces settings gear icon navigation)
- [ ] `CallerManagementScreen` shows all Callers as cards with enable toggle, schedule badge, and last-run info
- [ ] Tapping a Caller card opens `CallerDetailSheet` with description, schedule config (enable + time picker), and action buttons (Run, History, Reset)
- [ ] Enable/disable toggle calls `PUT /api/daily/callers/{name}` and reloads scheduler
- [ ] Schedule time picker calls `PUT /api/daily/callers/{name}` with new time
- [ ] `CardsEmptyState` links to `CallerManagementScreen` instead of `/settings`
- [ ] `DailyAgentsSection` in Settings simplified to a link → CallerManagementScreen (avoid duplicate UI)
- [ ] Backend: `POST /api/daily/callers/{name}/reset` endpoint implemented

## Context

### Existing Code

**Flutter widgets to refactor:**
- `DailyAgentsSection` (`app/lib/features/settings/widgets/daily_agents_section.dart`) — 553 lines, raw HTTP calls, full agent card rendering. This is the current management UI, but it lives inside Settings and uses `Map<String, dynamic>` instead of the `DailyAgentInfo` model.
- `CardsEmptyState` (`app/lib/features/daily/journal/widgets/cards_empty_state.dart`) — links to `/settings`, should link to new screen.
- `JournalHeader` (`app/lib/features/daily/journal/widgets/journal_header.dart`) — has settings gear at line 109.

**Flutter infrastructure already in place:**
- `DailyAgentInfo` model in `computer_service.dart` (lines 391-439) — name, displayName, description, scheduleEnabled, scheduleTime, outputPath, lastRunAt, runCount
- `DailyApiService.fetchCallers()` in `daily_api_service.dart` (line 353)
- `callersProvider` in `journal_providers.dart` (line 280) — `FutureProvider.autoDispose`
- `AgentTheme.forAgent()` in `agent_theme.dart` — icon/color per agent

**Backend endpoints (all exist except reset):**
- `GET /api/daily/callers` — list all
- `PUT /api/daily/callers/{name}` — update fields (schedule_enabled, schedule_time, enabled)
- `POST /api/daily/cards/{name}/run` — trigger run (202 Accepted)
- `POST /api/scheduler/reload` — reload scheduler config
- **MISSING**: `POST /api/daily/callers/{name}/reset` — Flutter already calls this (line 161) but backend returns 404

### Patterns to Follow

- `ConsumerWidget` / `ConsumerStatefulWidget` with Riverpod `ref.watch`
- `DailyApiService` for all server calls (not raw `http.get`)
- Design tokens: `Spacing.lg`, `Radii.card`, `BrandColors`, `Motion.gentle`
- Bottom sheets: `Flexible` + `SingleChildScrollView`, max height 85%
- Snackbar feedback for async operations

## Implementation Phases

### Phase 1: Backend — Reset endpoint
**Files:** `computer/modules/daily/module.py`

Add `POST /api/daily/callers/{name}/reset`:
- Verify Caller exists in graph
- Delete the Caller's agent session directory (`{vault}/Daily/.sessions/{name}/`)
- Return `{"status": "reset", "agent": name}`

Also add `updateCaller()` and `resetCaller()` methods to `DailyApiService` in Flutter so Phases 2-3 use the service layer instead of raw HTTP.

### Phase 2: CallerManagementScreen
**Files:** New `app/lib/features/daily/journal/screens/caller_management_screen.dart`

A full-screen page showing Callers as a list of `CallerCard` widgets:
- AppBar: "Daily Agents" title, back arrow
- Each card: Agent icon (via `AgentTheme`), display name, description (1 line), schedule badge, enable/disable toggle (Switch)
- Toggle immediately calls `PUT /api/daily/callers/{name}` with `enabled: true/false` + `POST /scheduler/reload`
- Tap card → open `CallerDetailSheet` (Phase 3)
- Pull-to-refresh reloads `callersProvider`
- Empty state: "No Callers configured yet" (shouldn't normally appear)

### Phase 3: CallerDetailSheet
**Files:** New `app/lib/features/daily/journal/widgets/caller_detail_sheet.dart`

Bottom sheet opened on Caller card tap:
- Header: Agent icon + display name + enable toggle
- Description section: Full description text
- Schedule section: Enable/disable schedule toggle + time picker (showTimePicker on tap)
- Actions row: Run Now, View History, Reset (with confirmation dialog)
- All mutations → `DailyApiService` → refresh `callersProvider`

### Phase 4: Wire up entry points
**Files:** `journal_header.dart`, `cards_empty_state.dart`, `daily_agents_section.dart`, `main.dart`

- `JournalHeader`: Settings gear navigates to `CallerManagementScreen` (push MaterialPageRoute), not generic `/settings`
- `CardsEmptyState`: "Set up" button navigates to `CallerManagementScreen`
- `DailyAgentsSection` in Settings: Replace inline agent list with a single "Manage Daily Agents →" ListTile that opens `CallerManagementScreen`. Keep reload scheduler button.
- Register `/callers` route in `main.dart` routes map (optional — could just use MaterialPageRoute push)

### Phase 5: Build & verify
- `flutter build macos`
- Manual test: open journal → tap header icon → see CallerManagementScreen → toggle enable → adjust schedule → run agent → view history → reset
- Verify `CardsEmptyState` links to new screen
- Verify Settings → Daily Agents links to new screen

## Dependencies & Risks

- **Reset endpoint**: Flutter already calls it but it 404s. Low risk — straightforward file deletion.
- **Scheduler reload**: Already works via `POST /scheduler/reload`. Toggling `enabled` needs this call afterward.
- **`enabled` vs `schedule_enabled`**: Two separate fields. `enabled` controls whether the Caller exists at all. `schedule_enabled` controls automatic runs. The toggle on the management screen controls `schedule_enabled` (the useful one). `enabled` stays true unless user explicitly deletes.

## References

- Brainstorm: `docs/brainstorms/2026-03-10-caller-management-ui-brainstorm.md`
- Backend CRUD: `computer/modules/daily/module.py` lines 1500-1620
- Current settings UI: `app/lib/features/settings/widgets/daily_agents_section.dart`
- API service: `app/lib/features/daily/journal/services/daily_api_service.dart`
- Providers: `app/lib/features/daily/journal/providers/journal_providers.dart`
