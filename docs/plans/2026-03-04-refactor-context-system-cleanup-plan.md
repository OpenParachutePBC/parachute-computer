---
title: "Cleanup: Context system naming collisions and duplicated constants"
type: refactor
date: 2026-03-04
issue: 83
priority: P3
labels: [computer]
---

# Context System Cleanup

Small housekeeping pass on the three context subsystems in `computer/`. No behavior changes — naming, placement, and one actual bug fix.

## Acceptance Criteria

- [x] `CHARS_PER_TOKEN = 4` exists in exactly one place (`lib/constants.py`)
- [x] `context_loader.py` and `context_folders.py` both import it from there
- [x] `ContextFile` in `context_parser.py` renamed to `ParsedContextFile`; all references updated
- [x] `imports.py` `GET /import/contexts` endpoint no longer crashes with `NameError` on `vault_path`
- [x] Orchestrator `_build_system_prompt()` routing has a clarifying comment
- [x] All unit tests pass

## Changes

### 1. Extract `CHARS_PER_TOKEN` → `parachute/lib/constants.py` (new file)

```python
# parachute/lib/constants.py
# Rough token estimation: average English word ≈ 4 chars, avg token ≈ 4 chars
CHARS_PER_TOKEN = 4
```

Update imports:
- `lib/context_loader.py:16` — remove local definition, `from .constants import CHARS_PER_TOKEN`
- `core/context_folders.py:24` — remove local definition, `from ..lib.constants import CHARS_PER_TOKEN`

### 2. Rename `ContextFile` → `ParsedContextFile` in `context_parser.py`

`context_parser.py` has `ContextFile` (a structured parsed context with facts/focus/history).
`context_folders.py` has `ContextFile` (a single file in a folder hierarchy chain).
Both names are correct for their domain, but two `ContextFile`s in the same codebase is a navigation hazard.

Rename the parser's class to `ParsedContextFile` — the smaller blast radius since only `imports.py` consumes it.

Files touched:
- `core/context_parser.py` — rename class + 3 method references
- `api/imports.py` — update the one import + any `ContextFile` references

### 3. Fix `NameError` in `GET /import/contexts` endpoint (`api/imports.py:347`)

**Bug:** `vault_path` is referenced but never defined in `list_context_files()`.

```python
# Current (crashes with NameError):
"path": str(ctx.path.relative_to(vault_path)),

# Fix: use the same root the parser was initialized with
"path": str(ctx.path.relative_to(Path.home())),
```

The parser is initialized with `ContextParser(Path.home())` three lines above, so `Path.home()` is the correct root. If the vault path ever becomes configurable here, both the parser init and this line should move together.

### 4. Add routing comment in `orchestrator._build_system_prompt()`

The current dispatch is:
```python
if ctx.endswith(".md"):
    file_paths.append(ctx)
else:
    folder_paths.append(ctx)
```

Add a comment explaining the convention — `.md` entries are individual files loaded via `context_loader`, everything else is a folder path walked by `context_folders`. No code change.

## Context

```
computer/parachute/
├── lib/
│   ├── constants.py         ← NEW
│   └── context_loader.py    ← imports CHARS_PER_TOKEN from constants
├── core/
│   ├── context_folders.py   ← imports CHARS_PER_TOKEN from lib.constants
│   │                           ContextFile class stays as-is
│   ├── context_parser.py    ← ContextFile → ParsedContextFile
│   └── orchestrator.py      ← comment added to _build_system_prompt()
└── api/
    └── imports.py           ← vault_path bug fixed, ParsedContextFile import updated
```

## What We're Not Doing

- Not consolidating the three context systems — they serve distinct purposes
- Not changing `context_folders.ContextFile` (larger blast radius, less confusing name)
- Not making the orchestrator routing more elaborate — a comment is enough at P3
