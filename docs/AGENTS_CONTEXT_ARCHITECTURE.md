# AGENTS.md Context Architecture

## Overview

This document describes the new context system for Parachute, where context is tied to **folders with AGENTS.md files** rather than flat context files. This enables:

1. **Hierarchical context** - Parent folders provide broader context
2. **Curator-tended context** - The curator agent maintains context files in real-time
3. **Project-based organization** - Context lives with the project/area it describes
4. **Flexible structure** - Users organize however they want (PARA, custom, etc.)

## Core Concepts

### Context = Folder Reference

Instead of selecting individual files like `Chat/contexts/general-context.md`, users select **folders** that contain an `AGENTS.md` or `CLAUDE.md` file:

```
Selected: Projects/parachute
Loads:    Projects/parachute/AGENTS.md (or CLAUDE.md)
```

### Parent Chain Inclusion

When a folder is selected, we automatically include all parent AGENTS.md files up to the vault root:

```
Selected folder: Projects/parachute

Context chain loaded (bottom-up):
1. ~/Parachute/AGENTS.md                    # Root context (always included)
2. ~/Parachute/Projects/AGENTS.md           # Projects overview
3. ~/Parachute/Projects/parachute/AGENTS.md # Parachute-specific

Optional deeper nesting:
4. ~/Parachute/Projects/parachute/chat/AGENTS.md  # Sub-project
```

### File Discovery Priority

For each folder in the chain, we look for:
1. `AGENTS.md` (preferred - Parachute convention)
2. `CLAUDE.md` (fallback - Claude Code convention)

If neither exists, that level is skipped (no error).

### Multiple Context Folders

A session can have multiple context folders selected. Each gets its full parent chain:

```
Selected: Projects/parachute, Areas/taiji

Full context loaded:
- ~/Parachute/AGENTS.md (shared root)
- ~/Parachute/Projects/AGENTS.md
- ~/Parachute/Projects/parachute/AGENTS.md
- ~/Parachute/Areas/AGENTS.md
- ~/Parachute/Areas/taiji/AGENTS.md
```

## Curator Responsibilities

The curator agent now tends to ALL context files in the chain:

1. **Direct contexts** - The AGENTS.md in selected folders
2. **Parent contexts** - The AGENTS.md files in parent folders
3. **Bubbling up** - Summarizing child project info into parent AGENTS.md

### Curator Tool Updates

The curator needs updated tools:

```python
# List all AGENTS.md files in the context chain
mcp__curator__list_context_files() -> [
    {"path": "AGENTS.md", "level": "root"},
    {"path": "Projects/AGENTS.md", "level": "parent"},
    {"path": "Projects/parachute/AGENTS.md", "level": "direct"},
]

# Update a specific AGENTS.md file
mcp__curator__update_context(
    file_path="Projects/parachute/AGENTS.md",
    section="facts",
    content="- Key fact about parachute"
)
```

## Database Schema

### New Table: session_contexts

```sql
CREATE TABLE IF NOT EXISTS session_contexts (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    folder_path TEXT NOT NULL,  -- Relative to vault (e.g., "Projects/parachute")
    added_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id, folder_path)
);

CREATE INDEX IF NOT EXISTS idx_session_contexts_session ON session_contexts(session_id);
CREATE INDEX IF NOT EXISTS idx_session_contexts_folder ON session_contexts(folder_path);
```

### Migration from Old System

Old context_files stored in session metadata will be migrated:
- `Chat/contexts/general-context.md` → Context from root `AGENTS.md`
- `Chat/contexts/parachute-context.md` → `Projects/parachute` folder

## Prompt Generation

### Order of Context in Prompt

Context is assembled in this order:

1. **Root AGENTS.md** - Broad user context
2. **Parent AGENTS.md files** - Category/area context (sorted by depth)
3. **Direct AGENTS.md files** - Specific project context
4. **Working directory CLAUDE.md** - Code-specific context (if different from above)

### Example Prompt Structure

```
## Project Knowledge

The following context has been loaded for your reference:

### Root Context (AGENTS.md)
[content of ~/Parachute/AGENTS.md]

### Projects Overview (Projects/AGENTS.md)
[content of ~/Parachute/Projects/AGENTS.md]

### Parachute Project (Projects/parachute/AGENTS.md)
[content of ~/Parachute/Projects/parachute/AGENTS.md]

---

## Working Directory Context

[content of CLAUDE.md from working directory, if different]
```

## API Changes

### New Endpoints

```
GET /api/contexts/folders
  Returns: List of folders that have AGENTS.md or CLAUDE.md files
  Response: [
    {"path": "Projects/parachute", "has_agents_md": true, "has_claude_md": true},
    {"path": "Areas/taiji", "has_agents_md": true, "has_claude_md": false},
  ]

GET /api/contexts/chain?folders=Projects/parachute,Areas/taiji
  Returns: Full context chain for given folders
  Response: {
    "files": [
      {"path": "AGENTS.md", "level": "root", "tokens": 500},
      {"path": "Projects/AGENTS.md", "level": "parent", "tokens": 200},
      ...
    ],
    "total_tokens": 1500
  }
```

### Modified Chat Request

```json
{
  "message": "Hello",
  "session_id": "...",
  "context_folders": ["Projects/parachute", "Areas/taiji"]
}
```

Note: `contexts` (old file paths) still supported for backwards compatibility.

## Flutter UI Changes

### Context Selection Sheet

Instead of showing files from `Chat/contexts/`, show folders:

```
Context Folders
─────────────────
☑ Projects/parachute
    AGENTS.md (1.2k tokens)

☐ Projects/unforced
    AGENTS.md (800 tokens)

☐ Areas/taiji
    AGENTS.md (400 tokens)

Parent contexts (auto-included):
  • AGENTS.md (root)
  • Projects/AGENTS.md
```

### Folder Browser

Add ability to browse vault folders and select those with AGENTS.md files.

## Migration Path

### Phase 1: Support Both Systems
- Keep old `contexts/` folder working
- Add new folder-based context alongside
- Curator can update both

### Phase 2: Migrate Existing Context
- Offer to move `Chat/contexts/*.md` into appropriate folders
- Update session references

### Phase 3: Deprecate Old System
- Remove `Chat/contexts/` special handling
- All context is folder-based

## File Format

AGENTS.md files follow the existing Parachute context format:

```markdown
# Project Name

> Brief description

---

## Facts
<!-- Key facts that can be updated by the curator -->
- Fact 1
- Fact 2

## Current Focus
<!-- What's actively being worked on -->
- Active task

## History
<!-- Append-only section for curator updates -->

<!-- Added by curator on 2025-01-06 12:00 UTC -->
- Completed feature X
```

The format is:
- Human-readable and editable
- Curator-parseable (structured sections)
- Token-efficient (concise bullet points)
- Compatible with markdown viewers

## Example Vault Structure

```
~/Parachute/
├── AGENTS.md                      # Root: who you are, your setup
├── Projects/
│   ├── AGENTS.md                  # Overview of all projects
│   ├── parachute/
│   │   ├── AGENTS.md              # Parachute project context
│   │   ├── chat/                  # Sub-project
│   │   │   └── AGENTS.md
│   │   └── base/
│   │       └── AGENTS.md
│   └── unforced/
│       └── AGENTS.md
├── Areas/
│   ├── AGENTS.md                  # Overview of life areas
│   ├── well-being/
│   │   └── AGENTS.md
│   ├── taiji/
│   │   └── AGENTS.md
│   └── music/
│       └── AGENTS.md
├── Resources/                      # Reference material (no AGENTS.md needed)
└── Archive/                        # Old projects (optional AGENTS.md)
```

## Open Questions

1. **Working directory vs context folder** - If working_directory is `Projects/parachute/base`, should we auto-add `Projects/parachute` as context? Or keep them separate?

2. **Context chain depth limit** - Should we limit how deep the parent chain goes? (Probably not needed initially)

3. **Conflict resolution** - If the same info is in parent and child AGENTS.md, which takes precedence? (Child should override)

4. **Token budgeting** - How to allocate tokens across multiple context files? (Simple: load all, truncate if needed)
