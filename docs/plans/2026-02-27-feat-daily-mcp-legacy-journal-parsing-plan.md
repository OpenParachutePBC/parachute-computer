---
title: "feat(daily): parse legacy Obsidian journal files in MCP"
type: feat
date: 2026-02-27
issue: 127
---

# feat(daily): parse legacy Obsidian journal files in MCP

## Overview

162 pre-frontmatter journal files (Feb 2025 – Dec 14, 2025) are invisible to the
Daily MCP. The three Daily MCP functions — `list_recent_journals`, `get_journal`,
and `search_journals` — assume every file contains `# para:daily:` entry markers.
Files without those markers return `entry_count: 0` and `entries: []` and are
therefore completely excluded from Brain's processing pipeline, Daily search, and
agent reflection.

This plan adds legacy format detection and fallback parsing to those three
functions. The fix is contained entirely in `computer/parachute/mcp_server.py`.

## Problem Statement

The parser in `get_journal()` (line 1170) splits file content on
`"\n# para:daily:"` and iterates `parts[1:]`, skipping everything before the
first marker. For legacy Obsidian files with no such markers, `parts[1:]` is
empty — the function returns an empty `entries` list despite the file existing
and `raw_content` being populated.

```python
# Current (mcp_server.py:1170)
parts = content.split("\n# para:daily:")
for i, part in enumerate(parts[1:], 1):   # skips all content on legacy files
    ...
```

`list_recent_journals()` (line 1138) counts `"# para:daily:"` occurrences:
```python
entry_count = content.count("# para:daily:")   # always 0 for legacy files
```

`search_journals()` (lines 1082-1083) uses the same split:
```python
entries = content.split("\n# para:daily:")
for i, entry in enumerate(entries[1:], 1):   # skips all content on legacy files
```

## Proposed Solution

Add a `_is_legacy_journal(content)` helper and update each function with a
fallback branch for legacy files. No new files, no schema changes — only
`mcp_server.py` is modified.

### Detection logic

```python
# mcp_server.py — new helper near line 1040
def _is_legacy_journal(content: str) -> bool:
    """True if content lacks para:daily: entry markers (pre-Dec 15 Obsidian format)."""
    return "# para:daily:" not in content
```

### `get_journal()` — legacy branch

When `_is_legacy_journal(content)`:
- Return the full file content as a single entry
- `id`: `f"legacy-{date}"` (deterministic, stable across reads)
- `time`: `None`
- `type`: `"legacy"` (signal to consumers)
- `entry_count`: `1`

```python
# mcp_server.py — get_journal() legacy path
if _is_legacy_journal(content):
    return {
        "date": date,
        "file": str(journal_file.name),
        "entry_count": 1,
        "entries": [{
            "id": f"legacy-{date}",
            "time": None,
            "type": "legacy",
            "content": content,
        }],
        "raw_content": content,
    }
```

### `list_recent_journals()` — legacy branch

When `_is_legacy_journal(content)`:
- Report `entry_count: 1` (it is one document)
- Add `"type": "legacy"` to distinguish from zero-entry new-format files

```python
# mcp_server.py — list_recent_journals() legacy path
if _is_legacy_journal(content):
    results.append({
        "date": journal_file.stem,
        "entry_count": 1,
        "file": str(journal_file.name),
        "type": "legacy",
    })
else:
    entry_count = content.count("# para:daily:")
    results.append({
        "date": journal_file.stem,
        "entry_count": entry_count,
        "file": str(journal_file.name),
    })
```

### `search_journals()` — legacy branch

When `_is_legacy_journal(content)` and query matches:
- Treat the entire file as one searchable unit
- `entry_header`: `f"legacy:{date}"` (placeholder, no structured header)
- Snippet: same window logic as current code

```python
# mcp_server.py — search_journals() legacy path
if _is_legacy_journal(content):
    if query_lower in content.lower():
        match_pos = content.lower().find(query_lower)
        start = max(0, match_pos - 50)
        end = min(len(content), match_pos + len(query) + 100)
        snippet = content[start:end]
        if start > 0:
            snippet = "..." + snippet
        if end < len(content):
            snippet = snippet + "..."
        results.append({
            "date": journal_file.stem,
            "entry_header": f"legacy:{journal_file.stem}",
            "snippet": snippet,
            "file": str(journal_file.name),
            "type": "legacy",
        })
else:
    # existing split-on-para:daily: logic unchanged
    ...
```

## Technical Considerations

- **No frontmatter parsing needed.** The existing new-format parser already ignores
  YAML frontmatter via the `parts[0]` skip. Legacy files have no frontmatter, so
  returning raw content is the right thing.
- **`daily_agent_tools.py` is unaffected.** The Daily agent already reads
  `journal_file.read_text()` as raw text and passes it straight to the agent.
  Legacy files already work there.
- **`type: "legacy"` field.** Adding this optional field to responses is backwards
  compatible — consumers that don't know about it will ignore it. Brain bridge and
  reflection agents can use it to adjust processing (e.g., skip structured entry
  extraction and treat as prose).
- **ID stability.** `f"legacy-{date}"` (e.g. `"legacy-2025-08-01"`) is stable and
  unique per file. No hash computation needed — date is already the natural key.
- **No write support.** Legacy files remain read-only. `create_entry()` always
  writes new-format files to `Daily/entries/`, which is a separate directory.

## Acceptance Criteria

- [ ] `get_journal("2025-08-01")` returns a non-null result with `entry_count: 1`
  and one entry containing the full file content for a legacy file
- [ ] `list_recent_journals()` lists legacy journal dates with `entry_count: 1`
  and `type: "legacy"` in the response
- [ ] `search_journals(query)` finds matches in legacy file content and returns
  snippets with `entry_header: "legacy:YYYY-MM-DD"`
- [ ] New-format files (`# para:daily:` present) are unaffected — behavior identical
  to before
- [ ] Unit tests cover: legacy `get_journal`, legacy `list_recent_journals`, legacy
  `search_journals`, new-format files unaffected
- [ ] No other files are modified

## Implementation

All changes are in `computer/parachute/mcp_server.py`.

### Step 1 — Add helper near line 1040

```python
# computer/parachute/mcp_server.py
def _is_legacy_journal(content: str) -> bool:
    """Return True if content lacks para:daily: markers (pre-Dec 15, 2025 Obsidian format)."""
    return "# para:daily:" not in content
```

### Step 2 — Update `search_journals()` (~line 1076)

Wrap the existing `entries = content.split(...)` block in an `else` branch.
Add a legacy branch before it that searches the whole file.

### Step 3 — Update `list_recent_journals()` (~line 1136)

Replace the `entry_count = content.count(...)` line with a conditional.

### Step 4 — Update `get_journal()` (~line 1165)

Add early-return legacy branch after reading `content` and before the `parts = content.split(...)` call.

### Step 5 — Add unit tests

New file: `computer/tests/unit/test_mcp_journals.py`

```python
# computer/tests/unit/test_mcp_journals.py
import pytest
from parachute.mcp_server import (
    _is_legacy_journal,
    get_journal,
    list_recent_journals,
    search_journals,
)

# Tests for _is_legacy_journal
# Tests for get_journal with legacy file
# Tests for get_journal with new-format file
# Tests for list_recent_journals with mixed files
# Tests for search_journals with legacy match
# Tests for search_journals with no legacy match
```

## References

- **Daily MCP functions**: `computer/parachute/mcp_server.py:1040-1198`
- **Tool schemas**: `computer/parachute/mcp_server.py:326-380`
- **Tool dispatch**: `computer/parachute/mcp_server.py:1278-1292`
- **Daily agent (unaffected)**: `computer/parachute/core/daily_agent.py`
- **Existing MCP tests**: `computer/tests/unit/test_mcp_session_metadata.py`
- **GitHub issue**: #127
