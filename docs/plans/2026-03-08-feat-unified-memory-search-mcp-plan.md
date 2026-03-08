---
title: Unified Memory Search MCP
type: feat
date: 2026-03-08
issue: 203
---

# Unified Memory Search MCP

Replace broken, fragmented MCP search tools with a single `search_memory` tool backed by the graph, fix the file lock bug at its root, and wire journal tools to the graph.

---

## Problem Statement

Five MCP tools are broken after the LadybugDB migration:

| Tool | Failure |
|------|---------|
| `search_sessions` | Lock error — opens DB file directly while server holds exclusive lock |
| `list_recent_sessions` | Same lock error |
| `list_recent_journals` | Returns `[]` — reads `~/Daily/journals/*.md` but data is now in `Note` graph nodes |
| `get_journal` | Returns "not found" — same file path issue |
| `search_journals` | Returns `[]` — same file path issue |

Root causes:
1. **`get_db()`** in `mcp_server.py` opens a new `BrainService` connection directly on the DB file. LadybugDB uses an exclusive lock; the running server already holds it. Any call to `get_db()` fails when the server is up.
2. **Journal functions** read markdown files at `~/Daily/journals/` — a path that no longer has current data. Journal entries live in `Note` nodes in the graph now.

Additionally, the existing search only covers `Chat.title` — not `Chat.summary` (where the rich bridge-generated summaries live), not `Exchange` content, not `Note.content`.

---

## Proposed Solution

### 1. Extend `/api/brain/memory` (brain API)

The existing `/memory` endpoint is the seed of what we need. Extend it to be a proper unified search endpoint:

- Search `Chat.summary` AND `Chat.title` (not just title — bridge summaries are the most useful field)
- Add `date_from` / `date_to` query params for date-scoped filtering
- Add `note_type` filter param (e.g. `journal`) for Notes
- Return a `snippet` field: ~200 chars centered around the match position
- Return `summary` field in session results

### 2. Add `search` param to `/api/brain/daily/entries`

Allow `?search=keyword` to filter Note results by `content CONTAINS $search`. Used by the fixed `search_journals` and `get_journal` tools.

### 3. Add `search` param to `/api/brain/sessions`

Allow `?search=keyword` to filter Chat results by `title CONTAINS $search OR summary CONTAINS $search`. Used by the fixed `search_sessions` tool.

### 4. Add `search_memory` MCP tool

New unified tool. Single call that searches across Chat summaries and Note content. Routes through `_brain_call("/memory?...")`. Parameters: `query` (required), `source` (optional: `"journal"` or `"chat"`), `date_from`, `date_to`, `limit`.

### 5. Fix the five broken tools — route through brain API

| Tool | New implementation |
|------|--------------------|
| `search_sessions` | `_brain_call("/sessions?search=...&limit=...")` |
| `list_recent_sessions` | `_brain_call("/sessions?limit=...&module=...&archived=...")` |
| `list_recent_journals` | `_brain_call("/daily/entries?limit=...")` |
| `get_journal` | `_brain_call("/daily/entries?date_from=date&date_to=date")` |
| `search_journals` | `_brain_call("/memory?source=journal&search=...&limit=...")` |

No more `get_db()` calls for these tools. The `_brain_call` helper already exists and works correctly.

---

## Technical Approach

### `computer/parachute/api/brain.py`

**`GET /memory`** — extend existing endpoint:
```python
# Add params:
date_from: str | None = Query(None)
date_to: str | None = Query(None)
note_type: str | None = Query(None)  # e.g. "journal"

# Session search: title OR summary
session_where_clauses.append("(s.title CONTAINS $search OR s.summary CONTAINS $search)")

# Note filtering by note_type
if note_type:
    note_where_clauses.append("e.note_type = $note_type")

# Date filtering on notes
if date_from:
    note_where_clauses.append("e.date >= $date_from")
if date_to:
    note_where_clauses.append("e.date <= $date_to")

# Snippet extraction helper
def _extract_snippet(content: str, query: str, window: int = 200) -> str:
    pos = content.lower().find(query.lower())
    if pos < 0:
        return content[:window] + ("..." if len(content) > window else "")
    start = max(0, pos - 80)
    end = min(len(content), pos + len(query) + 120)
    snippet = content[start:end]
    if start > 0: snippet = "..." + snippet
    if end < len(content): snippet = snippet + "..."
    return snippet

# In results: add snippet and summary fields
items.append({
    "kind": "session",
    "id": s.get("session_id", ""),
    "title": s.get("title") or "Untitled",
    "summary": s.get("summary") or "",
    "snippet": _extract_snippet(s.get("summary") or s.get("title") or "", search) if search else "",
    "ts": s.get("last_accessed") or s.get("created_at") or "",
    "module": s.get("module", "chat"),
})
items.append({
    "kind": "note",
    ...
    "snippet": _extract_snippet(e.get("content") or "", search) if search else "",
    "date": e.get("date"),
})
```

**`GET /sessions`** — add `search` param:
```python
search: str | None = Query(None)
# In where_clauses:
if search:
    where_clauses.append("(s.title CONTAINS $search OR s.summary CONTAINS $search)")
    params["search"] = search
```

**`GET /daily/entries`** — add `search` param:
```python
search: str | None = Query(None)
if search:
    where_clauses.append("e.content CONTAINS $search")
    params["search"] = search
```

---

### `computer/parachute/mcp_server.py`

**New `search_memory` tool definition** (add to `TOOLS` list):
```python
Tool(
    name="search_memory",
    description=(
        "Search all memory — chat sessions and journal entries — by keyword. "
        "Returns ranked results with summaries and matched snippets. "
        "By default searches everything; use 'source' to narrow to journals or chats. "
        "Use date_from/date_to to scope by date (YYYY-MM-DD)."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Keyword or phrase to search"},
            "source": {"type": "string", "description": "Optional: 'journal' or 'chat'"},
            "date_from": {"type": "string", "description": "Optional: YYYY-MM-DD"},
            "date_to": {"type": "string", "description": "Optional: YYYY-MM-DD"},
            "limit": {"type": "number", "default": 10},
        },
        "required": ["query"],
    },
)
```

**`handle_tool_call` additions / fixes:**
```python
elif name == "search_memory":
    params = {"search": arguments["query"]}
    if arguments.get("source") == "journal":
        params["type"] = "notes"
        params["note_type"] = "journal"
    elif arguments.get("source") == "chat":
        params["type"] = "sessions"
    if arguments.get("date_from"):
        params["date_from"] = arguments["date_from"]
    if arguments.get("date_to"):
        params["date_to"] = arguments["date_to"]
    params["limit"] = arguments.get("limit", 10)
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/memory{qs}")

# Fix search_sessions
if name == "search_sessions":
    params = {"search": arguments["query"], "limit": arguments.get("limit", 10)}
    if arguments.get("source"):
        params["source"] = arguments["source"]  # needs brain API support too, or just ignore
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/sessions{qs}")

# Fix list_recent_sessions
elif name == "list_recent_sessions":
    params = {"limit": arguments.get("limit", 20)}
    if arguments.get("module"):
        params["module"] = arguments["module"]
    if arguments.get("archived"):
        params["archived"] = "true"
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/sessions{qs}")

# Fix list_recent_journals
elif name == "list_recent_journals":
    params = {"limit": arguments.get("limit", 14)}
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/daily/entries{qs}")

# Fix get_journal
elif name == "get_journal":
    date = arguments["date"]
    params = {"date_from": date, "date_to": date, "limit": 50}
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/daily/entries{qs}")
    if result.get("count", 0) == 0:
        return json.dumps({"error": f"Journal not found for date: {date}"})

# Fix search_journals
elif name == "search_journals":
    params = {
        "search": arguments["query"],
        "type": "notes",
        "note_type": "journal",
        "limit": arguments.get("limit", 10),
    }
    if arguments.get("date_from"):
        params["date_from"] = arguments["date_from"]
    if arguments.get("date_to"):
        params["date_to"] = arguments["date_to"]
    qs = "?" + urllib.parse.urlencode(params)
    result = await _brain_call(f"/memory{qs}")
```

**Update tool descriptions** for the five fixed tools to reflect they now read from the graph.

---

## Acceptance Criteria

- [x] `search_memory` returns results from both Chat and Note nodes when called without `source` filter
- [x] `search_memory` with `source=journal` returns only Note results with `note_type=journal`
- [x] `search_memory` with `source=chat` returns only Chat results (with summary snippets)
- [x] `search_memory` with `date_from`/`date_to` correctly scopes Note results by date
- [x] `list_recent_sessions` returns recent sessions without lock error
- [x] `search_sessions` searches session summaries, not just titles
- [x] `list_recent_journals` returns recent journal entries from the graph (not empty)
- [x] `get_journal` returns entries for a specific date from the graph
- [x] `search_journals` returns results when searching journal content (e.g. "dream")
- [x] No broken tool calls `get_db()` (direct DB file access removed for these tools)
- [x] Results include `snippet` field with ~200-char excerpt around the matched text
- [x] Session results include `summary` field

---

## Dependencies & Risks

- **Tag tools** (`search_by_tag`, `list_tags`, `add_session_tag`, `remove_session_tag`) also use `get_db()` and are likely also broken under lock contention. Out of scope for this PR but should be tracked — they'd need brain API endpoints to fix.
- **Exchange content search** is not included in this PR. `search_memory` searches Chat summaries and Note content only. Exchange-level search (searching inside conversation turns) is a future layer.
- **`get_db()` function** remains in `mcp_server.py` for now (tag tools still reference it). Don't delete it — just stop calling it in the five fixed tools.
- Kuzu `CONTAINS` is case-sensitive. The current `/memory` endpoint already uses it this way. Worth noting but not blocking — we can add `LOWER()` wrapping in a follow-up.

---

## References

- Brainstorm: `docs/brainstorms/2026-03-08-unified-memory-search-mcp-brainstorm.md`
- `computer/parachute/mcp_server.py` — MCP tool definitions and handlers
- `computer/parachute/api/brain.py` — Brain API endpoints (already has `/memory`, `/sessions`, `/daily/entries`)
