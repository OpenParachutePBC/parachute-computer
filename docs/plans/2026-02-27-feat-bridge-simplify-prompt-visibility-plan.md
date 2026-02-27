---
title: "feat: Simplify bridge behavior + system prompt visibility"
type: feat
date: 2026-02-27
issue: 139
---

# feat: Simplify bridge behavior + system prompt visibility

## Overview

Two-phase work to clean up the bridge agent and make prompting inspectable from the app.

**Phase 1** removes the automatic brain graph writes from the bridge observer and tightens the
enrich prompt to a conservative default. The bridge becomes a reliable session-housekeeping tool
rather than an overambitious ambient AI.

**Phase 2** adds a prompt/instructions screen in Flutter where you can see the effective system
prompts for both main chat and bridge, and edit a personal instructions field (stored in
`vault/CLAUDE.md`) that feeds into both.

---

## Problem Statement

The bridge observer currently writes entities directly to the Brain graph after every exchange.
Without any personal context to judge against, it captures noise — dev architecture details about
Parachute itself, technical fixes, random patterns from development conversations. This undermines
trust in the knowledge graph and conflates "things I noticed" with "things I actually want to
remember."

Similarly, both the main chat system prompt and bridge prompts are completely invisible and
non-editable from the app. Prompting is the primary lever for shaping behavior, but there's no
way to inspect or tune it without editing source files.

---

## Phase 1 — Simplify Bridge Behavior

### 1a. Remove brain graph writes from observe()

**File:** `computer/parachute/core/bridge_agent.py`

Remove the BRAIN_FACTS parsing and entity upsert block from `observe()`:
- Delete parsing of `BRAIN_FACTS` JSON from response text (`_parse_brain_facts` call)
- Delete the entity upsert loop (`await brain.upsert_entity(...)` at ~lines 432-440)
- Delete `stored_entities` accumulation and the `brain_stored` count in `bridge_last_run` metadata
- Keep: MCP tool calls (update_title, update_summary, log_activity), `bridge_last_run` metadata write

The `brain` parameter in `observe()` signature can be removed once the writes are gone (or kept
as None-able if enrich still needs it).

Also update `bridge_last_run` metadata written to session — remove `brain_stored` key since nothing
is being stored anymore.

### 1b. Rewrite BRIDGE_OBSERVE_PROMPT

Strip the BRAIN_FACTS section entirely. New prompt should focus purely on session metadata quality:

```
You are a background observer for a conversation. After each exchange, update the session metadata using your tools.

Use update_title to set a concise 3-8 word title capturing the main topic. Only update if the title would substantially improve.
Use update_summary to write 1-3 sentences summarizing the full conversation so far.
Use log_activity to note in 1-2 sentences what happened in this specific exchange. Always call this.

Be concise. Focus on what was discussed and decided, not on technical minutiae.
```

### 1c. Tighten BRIDGE_ENRICH_PROMPT

Make the default posture PASS_THROUGH. Currently the prompt describes ENRICH as appropriate any
time "the user is making a request the chat agent will handle" — too broad. Rewrite to only enrich
on explicit personal references:

```
You are a context enrichment pre-processor. Evaluate whether the user message contains an explicit
reference to a specific person, project, organization, or commitment that might be in their knowledge graph.

Respond with ONE judgment:
- ENRICH: The message explicitly names a person, project, org, or commitment (e.g. "Kevin", "Woven Web",
  "the LVB cohort"). Generate 1-2 keyword search queries to retrieve relevant context.
- STEP_BACK: The user is explicitly asking to search or explore their brain/knowledge graph directly.
- PASS_THROUGH: Everything else — general conversation, coding, questions, tasks.

When in doubt, PASS_THROUGH. Do not enrich on vague or generic messages.

Respond in JSON only: {"judgment": "...", "queries": [...]}
```

### 1d. Keep enrich() short-circuit low

The current short-circuit skips messages under 5 words. That's fine — keep it. The tightened
prompt will do the heavier lifting on filtering.

### 1e. Remove bridge_context_log writes about brain storage

In `observe()`, the `bridge_context_log` currently appends a `writeback` entry whenever entities
are stored. Since we're removing entity storage, remove this writeback logging too. The column
can remain in the DB schema for future use — just stop writing to it.

---

## Phase 2 — System Prompt Visibility

### 2a. New server endpoint: GET /api/settings/prompts

**File:** `computer/parachute/api/settings.py` (new or add to existing)

Returns the current effective prompts for display in the UI:

```python
GET /api/settings/prompts

Response:
{
  "bridgeEnrichPrompt": "...",   # current BRIDGE_ENRICH_PROMPT constant
  "bridgeObservePrompt": "...",  # current BRIDGE_OBSERVE_PROMPT constant
  "vaultInstructions": "...",    # contents of vault/CLAUDE.md (or "" if not exists)
  "vaultInstructionsPath": "vault/CLAUDE.md"
}
```

The main chat system prompt preview already exists via `GET /prompt/preview` — no new endpoint
needed for that.

### 2b. New server endpoint: PUT /api/settings/instructions

Saves user-editable personal instructions to `vault/CLAUDE.md`:

```python
PUT /api/settings/instructions
Body: { "instructions": "..." }

Response: { "ok": true, "path": "vault/CLAUDE.md" }
```

This is the simplest path: vault CLAUDE.md is already injected into the main chat system prompt
by the orchestrator. Writing personal context there (projects, roles, relationships) means it
flows into main chat automatically. Future: also feed into bridge enrich prompt for better judgment.

### 2c. Flutter: Instructions / Prompts screen

**New file:** `app/lib/features/settings/screens/instructions_screen.dart`

A settings-style screen with two sections:

**Personal Instructions (editable)**
- `TextFormField` with multiline for editing vault CLAUDE.md contents
- Label: "Personal instructions" with subtitle "Injected into your chat sessions. Tell the AI who you are, what you're working on, what to remember."
- Save button → PUT /api/settings/instructions
- Shows save confirmation

**Prompt Viewer (read-only, collapsible)**
- Expandable section: "Bridge observe prompt" → shows current BRIDGE_OBSERVE_PROMPT
- Expandable section: "Bridge enrich prompt" → shows current BRIDGE_ENRICH_PROMPT
- Styled as code/monospace for readability
- Note: "These are default prompts. Custom prompting coming soon."

### 2d. Wire into settings navigation

**File:** `app/lib/features/settings/screens/settings_screen.dart`

Add an "Instructions & Prompts" navigation item in the settings screen that pushes to
`InstructionsScreen`. Place it in the top section alongside other key settings.

### 2e. Flutter service method

**File:** `app/lib/features/settings/services/settings_service.dart` (or existing service)

Add:
- `fetchPrompts()` → GET /api/settings/prompts
- `saveInstructions(String instructions)` → PUT /api/settings/instructions

---

## Acceptance Criteria

### Phase 1

- [x] Sending a chat message with dev/technical content does NOT result in new Brain entities
- [x] Bridge chip still appears and shows title/summary/activity updates
- [x] Sending a message like "what's the status of Woven Web?" triggers ENRICH (explicit project name)
- [x] Sending "write me a function to sort a list" results in PASS_THROUGH (check server logs)
- [x] `bridge_last_run` metadata no longer includes `brain_stored` key

### Phase 2

- [x] GET /api/settings/prompts returns current bridge prompts and vault instructions
- [x] PUT /api/settings/instructions writes to vault/CLAUDE.md and that content appears in next chat's system prompt
- [x] Instructions screen accessible from settings
- [x] Editable instructions field saves and persists across app restarts
- [x] Bridge prompts visible in read-only expandable sections

---

## Key Files

| File | Change |
|------|--------|
| `computer/parachute/core/bridge_agent.py` | Remove brain writes, rewrite OBSERVE + ENRICH prompts |
| `computer/parachute/api/settings.py` | Add /prompts and /instructions endpoints |
| `app/lib/features/settings/screens/instructions_screen.dart` | New screen |
| `app/lib/features/settings/screens/settings_screen.dart` | Add nav item |
| `app/lib/features/settings/services/settings_service.dart` | Add fetch/save methods |

---

## Out of Scope

- Staging markdown scratchpad
- Automatic brain graph writes / ambient capture
- Promotion agents or review UI
- Per-session prompt overrides (future)
- Editable bridge prompts (Phase 2 shows them read-only; editing is future work)
