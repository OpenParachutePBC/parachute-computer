---
title: "Fix sandbox message visibility — read container JSONL, kill synthetic mirror"
type: fix
date: 2026-03-18
issue: 287
---

# Fix Sandbox Message Visibility

Kill the synthetic transcript mirror for sandboxed sessions. Read messages directly from the container's bind-mounted JSONL, which is written incrementally by the SDK and already persists on the host filesystem.

## Problem

Messages in sandboxed chats appear "dropped" — the AI does the work but the response is invisible in the UI. This persists across app restarts. Root cause: the host-side synthetic mirror (`write_sandbox_transcript()`) only writes on the `"done"` event. If the SSE stream drops before that, no transcript is written. Meanwhile, the real SDK JSONL inside the container's bind-mounted home dir has everything.

## Acceptance Criteria

- [x] Sandboxed session messages load from the container's bind-mounted JSONL (`vault/.parachute/sandbox/envs/<slug>/home/.claude/projects/...`)
- [x] Messages are visible even if the SSE stream dropped before the `"done"` event
- [x] Full transcript viewer (`/api/chat/{id}/transcript`) reads from the container JSONL for sandboxed sessions
- [x] `write_sandbox_transcript()` is removed along with its call site in `_process_sandbox_event()`
- [x] Legacy sessions without `container_id` fall back to `~/.claude/projects/` path
- [x] History injection on sandbox retry still works (inherits the fix via `_load_sdk_messages()`)

## Solution

### Step 1: Add container-aware transcript path resolution

**File:** `computer/parachute/core/session_manager.py`

Add a new method `get_container_transcript_path(container_id, session_id)` that:
1. Constructs `vault/.parachute/sandbox/envs/{container_id}/home/.claude/projects/`
2. Searches subdirs for `{session_id}.jsonl` (the encoded CWD varies — could be `-home-sandbox`, `-workspace`, etc.)
3. Returns the path if found, None otherwise

The vault path is available via `self.vault_dir` (already on SessionManager).

### Step 2: Update `_load_sdk_messages()` to prefer container JSONL

**File:** `computer/parachute/core/session_manager.py` (lines 769–777)

`_load_sdk_messages(session)` already has the full session object. Change it to:
1. If `session.container_id` exists → try `get_container_transcript_path(session.container_id, session.id)`
2. If found → pass that path to `load_sdk_messages_by_id()` (or read directly)
3. If not found (container pruned) → fall back to existing `load_sdk_messages_by_id(session.id, session.working_directory)`

This keeps `load_sdk_messages_by_id()` unchanged for direct (non-sandboxed) sessions.

### Step 3: Update `get_session_transcript()` for full transcript viewer

**File:** `computer/parachute/core/orchestrator.py` (lines 2078–2156)

Currently searches `~/.claude/projects/` by iterating all subdirs. For sandboxed sessions:
1. Load the session from DB to get `container_id`
2. If `container_id` → search `vault/.parachute/sandbox/envs/{container_id}/home/.claude/projects/` instead
3. Fall back to current behavior if not found

### Step 4: Remove `write_sandbox_transcript()` and its call site

**File:** `computer/parachute/core/session_manager.py` — Delete `write_sandbox_transcript()` (lines 613–661)

**File:** `computer/parachute/core/orchestrator.py` — Remove the call in `_process_sandbox_event()` (lines 1352–1359):
```python
# DELETE THIS BLOCK:
if ctx.sbx["had_content"]:
    self.session_manager.write_sandbox_transcript(
        ctx.sandbox_sid,
        ctx.sbx["message"],
        ctx.sbx["content_blocks"],
        working_directory=ctx.effective_working_dir,
    )
```

Also remove `ctx.sbx["content_blocks"]` accumulation if no longer needed elsewhere. Check first — it may be used for the SSE event stream itself.

### Step 5: Clean up accumulated content tracking (if safe)

In `_process_sandbox_event()`, content blocks are accumulated in `ctx.sbx["content_blocks"]` for the synthetic transcript. Verify whether this list is used for anything else (e.g., SSE events, session stats). If it's only used by `write_sandbox_transcript()`, remove the accumulation logic too.

## Context

**Key paths:**
- Container home on host: `vault/.parachute/sandbox/envs/{slug}/home/`
- Container JSONL: `{container_home}/.claude/projects/{encoded_cwd}/{session_id}.jsonl`
- Encoded CWD examples: `-home-sandbox`, `-workspace`
- Synthetic mirror (being removed): `~/.claude/projects/{encoded_cwd}/{session_id}.jsonl`

**Session model** (`computer/parachute/models/session.py`): `container_id: Optional[str]` — the slug that maps to the env directory.

**The JSONL format is identical** — both the container SDK and the synthetic mirror write the same event types (`user`, `assistant`, `result`). The container JSONL may have additional SDK-internal events (`queue-operation`, etc.) but `load_sdk_messages_by_id()` already ignores unknown event types.

## Risks

- **Concurrent read/write**: Reading a JSONL the SDK is actively appending to. Low risk — JSONL is append-only, line-delimited. Worst case: a partially-written final line gets skipped.
- **Orphaned synthetic mirrors**: Existing mirror files in `~/.claude/projects/` won't be cleaned up. They're harmless — just stale files. Could add a cleanup migration later if desired.
