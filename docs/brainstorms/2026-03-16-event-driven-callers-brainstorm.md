---
title: Event-Driven Callers
status: brainstorm
priority: P1
date: 2026-03-16
labels: [daily, computer, app]
issue: 278
---

# Event-Driven Callers

## What We're Building

Extend the Caller system to support **event-driven triggers** alongside the existing schedule triggers. A Caller can fire in response to Note lifecycle events (entry created, transcription complete, tag added) with optional filters (note type, tags). Event-driven Callers operate on individual Notes — reading and transforming them — while scheduled Callers continue to produce Cards for a given day.

This turns transcription cleanup from hardcoded background logic into the first event-driven Caller, and opens the door for user-configured post-processing: auto-tagging, meeting summarization, brain linking, or anything a scoped agent with the right tools can do.

### Two Caller Modes

| | Scheduled Callers | Triggered Callers |
|---|---|---|
| **Fires when** | Cron time (e.g., daily at 21:00) | Note event (e.g., transcription complete) |
| **Context** | A day's entries | A single note |
| **Output** | Produces Cards | Transforms the Note |
| **Example** | Daily reflection | Transcription cleanup, auto-tagging |

Both are just Callers with different trigger configs and tool access. The system prompt and tools shape behavior.

## Why This Approach

### Callers as the general agent mechanism

The Caller system already has scheduling, sandboxed execution, trust levels, tool scoping, session persistence, and a Flutter UI. Rather than building a separate system for post-processing, we extend Callers with event triggers. This also lays groundwork for future convergence — the Bridge agent is conceptually a Caller triggered by "chat message received."

### Containment through tool boundaries

Callers with narrowly scoped tools (e.g., only `read_entry` + `update_entry_content`) can run liberally without concern about prompt engineering risk. Trust comes from the tool boundary, not the prompt. A cleanup Caller literally cannot do anything except read and modify the note it was triggered on.

### Transcription cleanup as the proof case

The `_cleanup_transcription` function is currently hardcoded in the transcription pipeline. Converting it to a triggered Caller:
- Makes it configurable (users can edit the cleanup prompt)
- Makes it optional (disable if you prefer raw transcriptions)
- Makes it visible (Caller activity surfaces in the UI)
- Proves the event-trigger pattern before we build more on it

## Key Decisions

### 1. Trigger schema

Add fields to the existing Caller table:

- `trigger_event` — which event fires this Caller (e.g., `"note.transcription_complete"`, `"note.created"`)
- `trigger_filter` — JSON object with optional conditions (e.g., `{"type": "voice"}`, `{"tags": ["meeting"]}`)

A Caller with `schedule_enabled: true` runs on schedule. A Caller with `trigger_event` set runs on events. Both can coexist on the same Caller if needed, but that's an edge case.

### 2. Event types (starting set)

| Event | Fires when | Typical use |
|---|---|---|
| `note.created` | New entry saved to graph | Auto-tagging, classification |
| `note.transcription_complete` | Voice transcription finishes | Cleanup, summarization |

Keep the initial set small. More events (tag added, entry updated, etc.) come later as needed.

### 3. Scoped tool sets for triggered Callers

Triggered Callers get **note-scoped tools** that operate on the triggering entry:

| Tool | Purpose |
|---|---|
| `read_entry` | Read the note that triggered this Caller |
| `update_entry_content` | Replace/modify the note's content |
| `update_entry_tags` | Add or modify tags on the note |
| `update_entry_metadata` | Update metadata fields (title, status, etc.) |

These are distinct from the existing day-scoped tools (`read_journal`, `write_output`). A cleanup Caller only needs `read_entry` + `update_entry_content`. A tagging Caller gets `read_entry` + `update_entry_tags`. Containment is granular.

### 4. Execution path

When a hook event fires (e.g., `daily.entry.transcription_complete`):
1. Query Callers where `trigger_event` matches and `enabled = true`
2. Apply `trigger_filter` against the note's metadata (type, tags, etc.)
3. For each matching Caller, invoke it with the entry_id as context
4. Caller runs via existing execution path (SDK direct or sandboxed)
5. Activity is visible in the UI (same pattern as Bridge agent)

### 5. Replace hardcoded cleanup with a Caller

Remove `_cleanup_transcription` from the transcription pipeline. Instead:
- Seed a built-in "transcription-cleanup" Caller with trigger = `note.transcription_complete`, filter = `{"type": "voice"}`, tools = `[read_entry, update_entry_content]`
- The existing `CLEANUP_SYSTEM_PROMPT` becomes this Caller's system prompt
- Enabled by default so the experience doesn't regress
- User can edit the prompt, disable it, or add additional triggered Callers

### 6. UI transparency

Caller activity on a Note surfaces the same way Bridge agent activity surfaces in Chat — collapsible inline section showing what happened. Since Callers run via Claude Agent SDK, we already have session transcripts to display.

### 7. Bug fix: transcription-cleanup Caller should not fire on schedule

Currently the app shows an error about the transcription-cleanup Caller failing to run, despite it not being a scheduled Caller. This suggests something in the scheduler or startup path is picking it up erroneously. Fix this as part of this work.

## Open Questions

1. **Concurrent triggers** — If a note is created AND transcription completes, should both events fire their Callers? Probably yes, but sequentially (cleanup runs, then tagging runs on the cleaned version). Need to define ordering.

2. **Failure handling** — If a triggered Caller fails, should we retry? Mark the note? Show an error in the UI? Currently `transcription_status: "failed"` handles this for cleanup, but we need a general pattern.

3. **Caller chaining** — Can one Caller's output trigger another? (e.g., cleanup finishes → fires `note.updated` → tagging Caller runs.) This is powerful but needs guard rails against loops. Probably defer to a later iteration.

4. **Bridge convergence timeline** — The Bridge agent could become a Caller with trigger = "chat.message_received". Not in scope for this iteration, but the trigger + filter + scoped-tools pattern should be designed with this in mind.

## Scope

### In scope
- `trigger_event` and `trigger_filter` fields on Caller schema
- Hook-to-Caller dispatch (event fires → match Callers → invoke)
- Note-scoped tool set (`read_entry`, `update_entry_content`, `update_entry_tags`, `update_entry_metadata`)
- Convert `_cleanup_transcription` to a triggered Caller
- UI: show Caller activity on Notes (reuse Bridge agent pattern)
- UI: configure trigger event and filter on Caller edit screen
- Fix the spurious transcription-cleanup scheduling error

### Out of scope (future)
- Caller chaining / pipelines
- Bridge agent convergence
- Additional event types beyond `note.created` and `note.transcription_complete`
- MCP tool access for triggered Callers (e.g., Suno)
- Conditional execution based on content analysis (beyond metadata filters)
