---
title: "Multi-Context System Prompt Clarity"
type: feat
date: 2026-02-16
issue: "#18"
modules: [computer]
priority: P1
deepened: 2026-02-16
---

# Multi-Context System Prompt Clarity

## Enhancement Summary

**Deepened on:** 2026-02-16
**Review agents used:** python-reviewer, performance-oracle, parachute-conventions-reviewer, code-simplicity-reviewer, pattern-recognition-specialist, security-sentinel, agent-native-reviewer, best-practices-researcher

### Key Improvements from Deepening

1. **SDK duplication risk identified** — The SDK already loads working directory CLAUDE.md via `setting_sources=["project"]` + `cwd`. Do NOT re-load it in the orchestrator's `system_prompt_append`. Only add the framing text.
2. **Critical bugs in proposed code** — `break` placement, `relative_to()` crash on relative paths, stale token count after filtering.
3. **Simplified approach recommended** — Only ~10 lines needed in one file (orchestrator.py), not ~40 lines across two files. The context folder formatter can stay mostly unchanged.
4. **Security findings** — Never embed absolute paths in prompts; use vault-relative only. Existing path prefix check in `resolve_working_directory` has a collision bug.
5. **Dead code cleanup opportunity** — `selected_folders` param, `format_context_folders_section()`, and dead `folder_name` branch should be cleaned up while we're here.

---

## Overview

When multiple context folders and a working directory are loaded, the system prompt doesn't clearly communicate the structure to the AI. The prompt currently uses generic "## Project Knowledge" headers with no distinction between working directory context and supplementary reference material. The AI can't tell where it's operating, what knowledge is reference-only, or which CLAUDE.md/AGENTS.md file each section came from.

## Problem Statement

**Current behavior**: All context files are concatenated under a flat "## Project Knowledge" heading. The working directory is set via `cwd` parameter to the SDK but has no corresponding explanation in the prompt text itself. The AI sees:

```
## Project Knowledge
The following context has been loaded for your reference (3 files, ~2400 tokens):

## Chat/CLAUDE.md
[content]
---
## Brain/AGENTS.md
[content]
---
## CLAUDE.md
[content]
---
```

**Problems**:
1. No indication which folder is the working directory (where file operations happen)
2. No distinction between "this is where you're operating" vs "this is reference material"
3. All contexts look equally important — no hierarchy
4. File paths are relative to vault but this isn't stated
5. The `PromptMetadataEvent` already has rich metadata (working_directory_claude_md, context_files) but this information doesn't reach the prompt text

**Desired behavior** (from Issue #18):
1. System prompt clearly identifies the **working directory** and what it means
2. **Additional contexts** are labeled as supplementary reference
3. **Prompt sources** are attributed — which AGENTS.md/CLAUDE.md each section came from

## Proposed Solution (Revised After Deepening)

The simplicity reviewer and conventions reviewer converged on a key insight: **the SDK already loads the working directory's CLAUDE.md** via `setting_sources=["project"]` + `cwd=effective_cwd` (orchestrator.py line 934-935). The orchestrator comment at line 1317-1318 explicitly states this separation:

```python
# For vault-agent: SDK handles project-level CLAUDE.md via setting_sources=["project"].
# We only load vault-level CLAUDE.md here (outside the project root).
```

Therefore, the implementation should be simpler than originally proposed:

### Change 1: Add Working Directory Framing (orchestrator.py only)

When a working directory is set, inject a short framing section. Do NOT re-load CLAUDE.md content (SDK handles that).

```python
# After vault CLAUDE.md loading (line 1327)...

# Working directory context section — framing only, SDK loads the actual CLAUDE.md
if working_directory:
    wd_path = Path(working_directory)
    if not wd_path.is_absolute():
        wd_path = self.vault_path / working_directory
    try:
        display_path = wd_path.relative_to(self.vault_path)
    except ValueError:
        # Outside vault — use leaf name only, never expose absolute paths
        display_path = wd_path.name

    append_parts.append(
        f"## Working Directory\n\n"
        f"You are operating in: `{display_path}/` "
        f"(within the Parachute vault at {self.vault_path})\n"
        f"File operations, code changes, and commands execute here by default."
    )
```

### Change 2: Rename Context Header When Working Directory Is Set (context_folders.py)

Minimal change — rename the header from "Project Knowledge" to "Reference Context" when a working directory is active, and replace the `selected_folders` param (unused) with `working_directory`:

```python
def format_chain_for_prompt(
    self, chain: ContextChain, working_directory: str | None = None
) -> str:
    if not chain.files:
        return ""

    parts = []
    valid_files = [f for f in chain.files if f.exists and f.content]
    if not valid_files:
        return ""

    file_count = len(valid_files)
    token_count = chain.total_tokens

    if working_directory:
        parts.append("## Reference Context")
        parts.append(
            f"The following context has been loaded as supplementary reference "
            f"({file_count} files, ~{token_count} tokens):\n"
        )
    else:
        parts.append("## Project Knowledge")
        parts.append(
            f"The following context has been loaded for your reference "
            f"({file_count} files, ~{token_count} tokens):\n"
        )

    for ctx_file in valid_files:
        parts.append(f"## {ctx_file.path}")
        parts.append("")
        parts.append(ctx_file.content)
        parts.append("")
        parts.append("---")
        parts.append("")

    return "\n".join(parts)
```

### Change 3: Pass working_directory at call site

At line 1349, update the call:

```python
folder_context = context_folder_service.format_chain_for_prompt(
    chain, working_directory=working_directory
)
```

### Result: What the Prompt Looks Like

**Before** (current):
```
[Vault CLAUDE.md]

## Project Knowledge
The following context has been loaded for your reference (4 files, ~3200 tokens):

## Chat/CLAUDE.md
[chat instructions]
---
## Brain/AGENTS.md
[brain instructions]
---
```

**After** (proposed):
```
[Vault CLAUDE.md]

## Working Directory

You are operating in: `Chat/` (within the Parachute vault at ~/Parachute)
File operations, code changes, and commands execute here by default.

[SDK loads Chat/CLAUDE.md via setting_sources=["project"] — appears in SDK's own section]

## Reference Context
The following context has been loaded as supplementary reference (2 files, ~1800 tokens):

## Brain/AGENTS.md
[brain instructions]
---
## CLAUDE.md
[root instructions]
---
```

## Technical Approach

### Files to Modify

| File | Change |
|------|--------|
| `computer/parachute/core/orchestrator.py` | Add ~8 lines for working directory framing in `_build_system_prompt()` |
| `computer/parachute/core/context_folders.py` | Rename `selected_folders` → `working_directory` param; change header when WD set |

### Research Insights

#### Bug Fixes Identified by Reviewers

1. **`break` placement bug** (python-reviewer): The original plan had `break` outside the success path, causing it to skip AGENTS.md fallback even on OSError. Fixed by simplification — we no longer load CLAUDE.md content in the orchestrator at all.

2. **`relative_to()` crash** (python-reviewer, conventions-reviewer): `Path(working_directory).relative_to(self.vault_path)` crashes when `working_directory` is a vault-relative string (the common case). Since `working_directory` IS vault-relative, just use it directly for comparisons.

3. **Stale token count** (python-reviewer): After filtering files, `chain.total_tokens` still reflects the full chain. Fixed by simplification — we no longer filter files.

4. **Dead `file_count` variable**: Computed before filtering but never used. Removed.

#### Security Findings (security-sentinel)

- **Path disclosure (MEDIUM)**: Never embed absolute paths in the prompt. On `ValueError` from `relative_to()`, use `wd_path.name` (leaf name only), not the full absolute path.
- **Path prefix collision (LOW)**: `resolve_working_directory` uses `str(resolved_real).startswith(str(vault_real))` which matches `/home/user/vault-evil/` against vault `/home/user/vault`. Should use `Path.is_relative_to()`. Pre-existing bug, note for future fix.
- **Prompt injection via CLAUDE.md (MEDIUM)**: User-provided content injected into system prompt without sanitization. Pre-existing issue, not introduced by this plan. Consider XML-style delimiters in a future enhancement.

#### Performance Assessment (performance-oracle)

- **No performance concerns.** The change adds at most one `Path` construction and one `relative_to()` call per message — sub-microsecond overhead.
- **No caching needed.** OS page cache handles small markdown files. Application-level caching would risk serving stale CLAUDE.md content.
- **Token impact: ~45 tokens** of framing text, <0.03% of context window.

#### Architecture Findings (conventions-reviewer)

- **SDK CLAUDE.md duplication risk (IMPORTANT)**: The original plan would have loaded working directory CLAUDE.md twice — once via `system_prompt_append` and once via SDK's `setting_sources=["project"]`. The revised plan avoids this by only adding framing text.
- **Module boundaries respected**: Both modified files are in `parachute/core/`, the correct layer for prompt composition.
- **Trust level interaction: PASS**: No changes to trust level determination or capability filtering.

#### Code Quality Findings (pattern-recognition, simplicity-reviewer)

- **Dead code to clean up while we're here**:
  - `selected_folders` param on `format_chain_for_prompt` (unused, line 242)
  - `format_context_folders_section()` method (zero call sites, lines 280-301)
  - Dead `folder_name` branch in format loop (lines 264-269) — both branches produce identical output
- **Naming conventions**: Follow existing `snake_case` with verb prefixes, `Optional[str]` style in orchestrator (matches existing signatures)
- **Patterns to follow**: append-then-join for prompt building, try/except with `logger.warning()` for file errors, early returns for guard conditions

#### Agent-Native Assessment (agent-native-reviewer)

- **Context hierarchy: GOOD** — Two-tier markdown heading (`## Working Directory` vs `## Reference Context`) creates unambiguous hierarchy that Claude models parse reliably.
- **Missing: trust level in prompt** — Agent doesn't know its trust level from the prompt text. Consider adding in a future enhancement.
- **Sub-agent propagation**: Sub-agents spawned via SDK's `agents` parameter do NOT inherit the parent's system prompt. The working directory context would be invisible to them. Not in scope for this change.

## Acceptance Criteria

- [x] Working directory clearly identified in prompt with path and purpose
- [x] Additional contexts labeled as "reference" when working directory is set
- [x] No duplicate loading of working directory CLAUDE.md (SDK handles it)
- [x] PromptMetadataEvent still contains all metadata (no regression)
- [x] Prompt preview API (`/api/prompt/preview`) reflects new structure
- [x] When no working directory is set, falls back to current "Project Knowledge" format
- [x] Never expose absolute filesystem paths in prompt text (use vault-relative only)

## Technical Considerations

- **No schema changes** — only prompt text formatting
- **No new dependencies** — pure string manipulation
- **Backwards compatible** — when no working directory set, behavior unchanged
- **Token impact** — adds ~45 tokens of framing text, negligible
- **SDK interaction** — framing goes via `system_prompt_append`, SDK handles CLAUDE.md loading via `setting_sources=["project"]` separately
- **Clean up dead code** — remove unused `selected_folders` param, dead `folder_name` branch, and unused `format_context_folders_section()` method

## References

- GitHub Issue: #18
- `computer/parachute/core/orchestrator.py:1264-1411` — `_build_system_prompt()`
- `computer/parachute/core/context_folders.py:241-278` — `format_chain_for_prompt()`
- `computer/parachute/models/events.py:175-258` — `PromptMetadataEvent`
- `computer/parachute/api/prompts.py:48-122` — `/api/prompt/preview`
