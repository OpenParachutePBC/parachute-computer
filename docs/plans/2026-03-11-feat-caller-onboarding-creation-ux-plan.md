---
title: "feat: Caller onboarding & creation UX"
type: feat
date: 2026-03-11
issue: 231
---

# Caller Onboarding & Creation UX

Closes the dead-end empty state in Caller Management by adding: a server-side template endpoint for seed callers, a `createCaller` API call from Flutter, a caller creation/editing form, and an improved empty state with a "Create your first caller" action.

## Acceptance Criteria

- [x] Server exposes `GET /api/daily/callers/templates` returning a list of starter caller definitions
- [x] "Daily Reflection" template ships as the first (and for now, only) template with a real system prompt
- [x] Empty state in CallerManagementScreen shows available templates with a "Create" action
- [x] Tapping "Create" provisions the caller via `POST /api/daily/callers` and reloads the list
- [x] Caller is created with `schedule_enabled: false` — user explicitly opts in to automation
- [x] CallerDetailSheet gains an "Edit" action that opens a caller editing form
- [x] Editing form supports: display name, description, system prompt (markdown text area), context/tool toggles, schedule config
- [x] Context/tool toggles map human labels to underlying tool names with configurable depth where applicable
- [x] `DailyAgentInfo` model extended with `systemPrompt`, `tools`, `trustLevel` fields
- [x] `fetchCallers()` in DailyApiService passes through all fields including system_prompt and tools
- [x] `createCaller()` and `deleteCaller()` methods added to DailyApiService
- [x] FAB or "+" button on CallerManagementScreen for creating additional callers (blank or from template)

## Context

### Current State

- Server has full CRUD on `/api/daily/callers` (POST create, PUT update, GET list/single, DELETE)
- Flutter has `fetchCallers()`, `updateCaller()`, `resetCaller()`, `reloadScheduler()` — but no `createCaller()` or `deleteCaller()`
- `DailyAgentInfo` model only carries: name, displayName, description, scheduleEnabled, scheduleTime, outputPath — missing systemPrompt, tools, trustLevel
- `fetchCallers()` maps only 5 fields from the server response, discarding system_prompt and tools
- Empty state says "Create a Caller on the server to get started" — dead end
- CallerDetailSheet is read-only for name/description, editable only for schedule

### Key Files

| File | Role |
|------|------|
| `computer/modules/daily/module.py` | Server endpoints — add templates endpoint |
| `app/lib/core/services/computer_service.dart` | `DailyAgentInfo` model — extend fields |
| `app/lib/features/daily/journal/services/daily_api_service.dart` | API client — add create/delete, extend fetch |
| `app/lib/features/daily/journal/screens/caller_management_screen.dart` | Management screen — update empty state, add FAB |
| `app/lib/features/daily/journal/widgets/caller_detail_sheet.dart` | Detail sheet — add Edit action |
| **New:** `app/lib/features/daily/journal/screens/caller_edit_screen.dart` | Full-screen editing form |

### Tool ↔ Label Mapping

The `tools` JSON array on the Caller node maps to human-friendly labels in the UI:

| Tool name | UI Label | Configurable |
|-----------|----------|-------------|
| `read_journal` | Today's journal | on/off |
| `read_recent_journals` | Recent journals | on/off + lookback (7/14/30 days) |
| `read_chat_log` | Chat logs | on/off |
| `read_recent_sessions` | Recent chat sessions | on/off |

`write_output` is always present and not shown in the UI — it's the tool the agent uses to save its Card output.

The lookback configuration for `read_recent_journals` is not currently stored anywhere on the Caller node. For v1, we'll show the toggle but defer the lookback config to a future iteration (the tool defaults to 7 days).

## Implementation

### Phase 1: Server — Templates Endpoint

Add `GET /api/daily/callers/templates` to `module.py`:

```python
@router.get("/callers/templates")
async def list_caller_templates():
    """Return starter Caller templates for onboarding."""
    return {"templates": CALLER_TEMPLATES}
```

Define `CALLER_TEMPLATES` as a module-level constant — a list of dicts with the same shape as the create endpoint body. Start with one:

```python
CALLER_TEMPLATES = [
    {
        "name": "daily-reflection",
        "display_name": "Daily Reflection",
        "description": "Reviews your journal entries and offers a thoughtful daily reflection",
        "system_prompt": """...""",  # Real prompt with {user_name}, {user_context} variables
        "tools": ["read_journal", "read_chat_log", "read_recent_journals"],
        "schedule_time": "21:00",
        "trust_level": "sandboxed",
    },
]
```

The system prompt should be a well-crafted markdown prompt that:
- Reads today's journal entries
- Reads recent journals for narrative continuity
- Produces a reflective, encouraging card
- Uses `{user_name}` and `{user_context}` template variables

### Phase 2: Flutter — Extend Model & API

**DailyAgentInfo** — add fields:
- `String systemPrompt` (default `""`)
- `List<String> tools` (default `[]`)
- `String trustLevel` (default `"sandboxed"`)

**DailyApiService** — changes:
1. `fetchCallers()` — pass through `system_prompt`, `tools` (parse JSON string to list), `trust_level`
2. Add `createCaller(Map<String, dynamic> body)` — POST to `/api/daily/callers`, returns created caller or null
3. Add `deleteCaller(String name)` — DELETE to `/api/daily/callers/{name}`, returns bool
4. Add `fetchTemplates()` — GET to `/api/daily/callers/templates`, returns list of template maps

### Phase 3: Flutter — Empty State with Templates

Replace `_EmptyCallersView` in `caller_management_screen.dart`:

Instead of a static "no agents" message, fetch templates from the server and show them as tappable cards:
- Each template card shows: icon, display name, description, "Create" button
- Tapping "Create" calls `createCaller()` with the template data (overriding `schedule_enabled: false`)
- After creation, calls `reloadScheduler()` and `ref.invalidate(callersProvider)` to refresh the list
- If template fetch fails, fall back to a "Create blank caller" button

Add a provider: `final templatesProvider = FutureProvider(...)` that fetches templates.

### Phase 4: Flutter — Caller Edit Screen

New file `caller_edit_screen.dart` — a full-screen form for creating or editing a caller.

**Parameters:**
- `DailyAgentInfo? caller` — null for new caller, non-null for editing
- `Map<String, dynamic>? template` — optional template to pre-fill from

**Form sections:**

1. **Name & Description**
   - Display name: `TextFormField`
   - Description: `TextFormField` (one-liner)
   - Name (slug): auto-generated from display name for new callers, read-only for existing

2. **System Prompt**
   - Full-height `TextFormField` with `maxLines: null`, monospace font
   - Helper text mentioning `{user_name}` and `{user_context}` variables

3. **Context Sources** (tool toggles)
   - `SwitchListTile` for each tool with human-friendly labels
   - Each tile shows: label, description of what it does, toggle
   - Maps to/from the `tools` list

4. **Schedule** (reuse existing pattern)
   - Enable/disable toggle
   - Time picker when enabled

**Save action:**
- For new callers: `createCaller()` + `reloadScheduler()`
- For existing: `updateCaller()` with changed fields + `reloadScheduler()` if schedule changed
- Pop back to management screen, invalidate providers

### Phase 5: Flutter — Wire Up Entry Points

1. **CallerManagementScreen** — add a FAB (`FloatingActionButton`) that opens CallerEditScreen in create mode (blank)
2. **CallerDetailSheet** — add an "Edit" `_ActionButton` that pops the sheet and opens CallerEditScreen in edit mode
3. **Empty state template cards** — on create, open CallerEditScreen pre-filled from template so user can review before saving (rather than silently creating)

### Phase 6: Clean Up

- Remove `outputPath` from `DailyAgentInfo` (vestigial, always `""` now)
- Remove `DailyAgentInfo.fromJson()` factory (uses old nested shape nobody calls anymore)
- Remove `outputDirectory` getter

## Dependencies & Risks

- **No external deps** — all changes are within the existing stack
- **System prompt quality matters** — the Daily Reflection template prompt needs to be well-crafted; a bad first impression undermines the feature
- **Mobile text editing** — editing a markdown prompt on a phone is awkward. V1 accepts this limitation; v2 could add a structured prompt builder or AI-assisted refinement
- **Tool filtering not enforced server-side** — the `tools` list on the Caller is passed through but `create_daily_agent_tools()` currently registers all tools regardless. This is fine for v1 (the tools are all read-only) but will matter when MCP tools are added
