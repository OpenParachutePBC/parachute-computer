# Cleanup: Context system naming collisions and duplicated constants

> The three context subsystems in `computer/` serve genuinely different purposes and should stay separate — but they share a duplicated constant and two classes with the same name, which creates unnecessary confusion for contributors.

**Date:** 2026-02-20
**Status:** Brainstorm
**Priority:** P3
**Modules:** computer
**Tags:** cleanup, context

---

## What We're Exploring

The `computer/` server has three context subsystems, each solving a different problem. They coexist correctly, but two implementation-level problems have crept in: a constant (`CHARS_PER_TOKEN = 4`) is defined identically in two files, and two classes are both named `ContextFile` despite having completely different shapes. Neither problem affects runtime behavior today, but both are contributor traps waiting to happen.

## Context

### The Three Systems (All Intentional, All Used)

**1. `context_parser.py` — Structured Parachute context files**
Parses files with Parachute-native `Facts / Focus / History` section headers. Produces structured data for import. Used exclusively by the `/import/contexts` API endpoint in `imports.py`. This is the right tool for Parachute's opinionated context format.

**2. `context_loader.py` — Legacy file-based loader**
Loads arbitrary vault files matching glob patterns. Used as a fallback path in `orchestrator._build_system_prompt()` when context entries are `.md` file paths (not folder paths). Provides raw file content without structural parsing.

**3. `context_folders.py` — Folder hierarchy system**
The primary context system. Walks folder hierarchies reading `AGENTS.md` / `CLAUDE.md` chains. Used as the main path in `orchestrator._build_system_prompt()` and exposed via the context folder API endpoints. This is the everyday context injection mechanism.

### Problem 1: Duplicated Constant

`CHARS_PER_TOKEN = 4` is defined identically in:
- `context_loader.py` line 16
- `context_folders.py` line 24

These are the same magic number. If the estimate ever needs updating (e.g., switching to a more accurate tokenizer), a contributor updating one file will silently miss the other.

### Problem 2: Two `ContextFile` Classes With the Same Name

`context_parser.py` (line 23) and `context_folders.py` (line 45) both define a class called `ContextFile`. They have different shapes — one models a parsed structured context file from the import flow, the other models a file entry in a folder hierarchy chain.

Any import statement that pulls `ContextFile` from either module is a potential source of IDE confusion, autocomplete errors, or `isinstance()` mistakes. A new contributor searching the codebase for `ContextFile` will find two definitions with no obvious signal about which is which.

### Problem 3 (Minor): Extension-Based Routing in Orchestrator

`_build_system_prompt()` routes context entries with this logic:

```python
if ctx.endswith(".md"):
    file_paths.append(ctx)
else:
    folder_paths.append(ctx)
```

This works, but it detects type by file extension rather than by any explicit marker. It's the lowest-priority issue — the behavior is fine — but it's worth a comment or a more deliberate dispatch if the routing logic ever grows.

## Why This Matters

- **Contributor confusion**: Two classes named `ContextFile` in the same codebase is a clear readability hazard. A contributor tracing a bug from `context_folders.py` who encounters a `ContextFile` reference has to verify which one they're looking at.
- **IDE ambiguity**: Type checkers and autocompleters will surface both definitions interchangeably, making "go to definition" unreliable.
- **Silent drift**: The duplicated constant means a future change (more accurate token estimate, switching libraries) requires remembering to update two files. One will inevitably be missed.
- **No behavior change required**: This is pure housekeeping. The fix is small and safe.

## Proposed Approach

### Step 1: Extract `CHARS_PER_TOKEN` to a shared location

Move the constant to a single shared module. Two reasonable options:
- `parachute/lib/constants.py` — a general constants file (good if other shared constants accumulate here)
- `parachute/lib/token_utils.py` — a small token-estimation utility (good if token counting helpers grow)

Both `context_loader.py` and `context_folders.py` import from the shared location. The constant disappears from both files.

### Step 2: Rename `ContextFile` in `context_parser.py`

Rename the class in `context_parser.py` to `ParsedContextFile`. This name signals:
- It came from the parser (not the folder system)
- It is a fully parsed, structured object (not a raw file entry)

The rename touches `context_parser.py` and `imports.py` (the only consumer). It does not touch `context_folders.py` or the orchestrator.

Alternatively, rename the class in `context_folders.py` to `ContextChainFile` — either direction resolves the collision. `ParsedContextFile` in the parser is the cleaner semantic fit.

### Step 3 (Optional, Lower Priority): Make orchestrator routing more explicit

Add a comment to the `endswith(".md")` branch explaining that `.md` entries are routed to the file loader and everything else is treated as a folder path. Alternatively, introduce a lightweight type tag or a named function (`_is_file_context`, `_is_folder_context`) to make the dispatch self-documenting.

This is low enough priority that it can be deferred or skipped.

## What We Are NOT Doing

- **Not consolidating the three systems.** They serve genuinely different purposes:
  - `context_parser.py` is for structured import (a specific API endpoint)
  - `context_loader.py` is the fallback for arbitrary file paths
  - `context_folders.py` is the primary runtime injection mechanism
  Merging them would destroy useful separation of concerns for no gain.
- **Not changing any behavior.** This is naming and placement only. No API changes, no runtime changes.
- **Not deleting any system.** All three are actively used.

## Open Questions

1. **Where does `CHARS_PER_TOKEN` live?**
   - `parachute/lib/constants.py` is simple and familiar. Good default.
   - `parachute/lib/token_utils.py` is more forward-looking if we ever add a real tokenizer. Possibly premature.
   - Start with `constants.py`; promote to `token_utils.py` only if token-related helpers accumulate.

2. **Which `ContextFile` gets renamed?**
   - Renaming in `context_parser.py` (to `ParsedContextFile`) has smaller blast radius — `imports.py` is the only consumer.
   - Renaming in `context_folders.py` (to `ContextChainFile`) touches more files (orchestrator, context folder endpoints).
   - Prefer renaming in `context_parser.py`.

3. **Is the extension-based routing in the orchestrator worth addressing now?**
   - At P3 priority, probably not — a comment is sufficient for now.

**Issue:** #83
