# Caller Management UI

**Status:** Brainstorm
**Priority:** P2
**Labels:** daily, app
**Issue:** #221

---

## What We're Building

A Flutter UI for browsing, enabling, configuring, and triggering Callers. The backend CRUD API already exists (`POST/PUT/DELETE /api/daily/callers`). Flutter currently has display-only widgets (`AgentTriggerCard`, `DailyAgentsSection` in settings). This adds the management layer that lets users control which Callers are active and how they behave.

Two audiences, two modes:
- **Parachute Daily (product):** Curated, pre-built Callers that ship with the app. Users browse a library, enable the ones they want, configure schedule. They don't author Callers — they choose from what we provide.
- **Parachute Computer (power user):** Full Caller authoring via Chat with MCPs. The management UI still matters for viewing status and triggering runs, but creation happens conversationally.

## Why This Matters

Callers are only valuable if people can discover and activate them. Right now the only way to create a Caller is writing a vault markdown file or hitting the API directly. For Parachute Daily as a product, users need to see what's available, understand what each Caller does, and turn them on with a tap.

This is also the configuration surface for scheduling — when do agents run, how often, what do they have access to. Without this UI, Callers are invisible infrastructure.

## Current State

**Backend (complete):**
- `GET /api/daily/callers` — list all Callers
- `GET /api/daily/callers/{name}` — get specific Caller
- `POST /api/daily/callers` — create/update Caller
- `PUT /api/daily/callers/{name}` — update fields
- `DELETE /api/daily/callers/{name}` — delete Caller
- Caller schema: `name`, `display_name`, `description`, `system_prompt`, `tools`, `model`, `schedule_enabled`, `schedule_time`, `enabled`, `trust_level` (after sandbox brainstorm)

**Flutter (display only):**
- `DailyAgentInfo` model (name, displayName, description, scheduleEnabled, scheduleTime, etc.)
- `fetchCallers()` in `daily_api_service.dart`
- `AgentTriggerCard` — displays agent with run button
- `DailyAgentsSection` — lists agents in settings
- No create/edit/delete UI, no scheduling configuration

## Key Decisions

**Library-first, not editor-first.**
For Parachute Daily, the primary interaction is browsing a library of available Callers and toggling them on/off. This is a card grid or list with clear descriptions, preview of what the Caller produces, and an enable toggle. The system prompt editor is secondary — most users never touch it.

**Ship with a curated starter set.**
Launch with 3-5 well-crafted Callers that demonstrate the value:
- **Daily Reflection** — reviews your recent journal entries and offers a thoughtful reflection
- **Weekly Review** — end-of-week summary and patterns (runs Sundays)
- **Morning Prompt** — a journaling prompt tailored to your recent themes
- These ship as default Callers in the graph (via migration), disabled by default so users opt in

**Schedule configuration inline.**
Each Caller card in the management UI shows its schedule and lets you adjust: enable/disable schedule, set time, set frequency (daily/weekly/custom). This lives on the Caller detail view, not buried in settings.

**Run history visible per Caller.**
Show last run time, run count, and status for each Caller. Link to the generated Card so users can see what it produced. This builds trust — you can see exactly what each agent is doing.

**Accessible from Daily's main screen.**
A settings gear or "Manage Callers" entry point from the journal screen, not hidden deep in app settings. Users should find this within one tap of their daily view.

## What Changes

**Flutter (`app/`):**
- New: `CallerLibraryScreen` — browse available Callers as cards
- New: `CallerDetailSheet` — view description, preview, schedule config, run history
- New: `CallerCard` widget — library card with enable toggle, status indicator
- Update: `DailyAgentsSection` in settings → link to CallerLibraryScreen
- Update: `daily_api_service.dart` — add `updateCaller()`, `deleteCaller()` methods
- Update: `journal_screen.dart` — add entry point to Caller management

**Backend (minimal):**
- Ship default Caller definitions via migration (similar to existing vault → graph migration)
- Ensure scheduler reload picks up enable/disable changes immediately

## Open Questions

- Should the starter Callers ship as part of the app bundle or be fetched from a server? App bundle is simpler and works offline. Server allows updates without app releases.
- Do we want a "preview" mode where you can see what a Caller would produce before enabling it? Compelling but complex — probably v2.
- How do power users share custom Callers? Export as JSON/YAML? Community repository? Future concern, but worth keeping the data model exportable.
- Should there be a "Caller of the day" or featured Caller rotation for new users? Fun but premature.
