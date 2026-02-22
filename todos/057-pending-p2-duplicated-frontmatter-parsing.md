---
status: pending
priority: p2
issue_id: 75
tags: [code-review, quality, python]
dependencies: []
---

# YAML Frontmatter Parsing Duplicated 4-5 Times

## Problem Statement

The pattern `content.split("---", 2)` + `yaml.safe_load(parts[1])` + field extraction is copy-pasted across 4-5 locations. The deleted `_parse_markdown_agent()` centralized this, but the consolidation replaced it with inline copies.

## Findings

- **Source**: git-history-analyzer (P2, confidence 90), pattern-recognition-specialist (P2, confidence 95)
- **Location**: `api/agents.py:94-106`, `api/agents.py:165-177`, `api/capabilities.py:52-57`, `api/plugins.py:330-342`, `core/plugin_installer.py`
- **Evidence**: Near-identical YAML frontmatter parsing blocks in 4-5 locations

## Proposed Solutions

### Solution A: Extract shared utility function (Recommended)
Create `lib/frontmatter.py` with `parse_frontmatter(content: str) -> tuple[dict, str]`.
- **Pros**: DRY, single place to maintain, consistent behavior
- **Cons**: New file
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `api/agents.py`, `api/capabilities.py`, `api/plugins.py`, `core/plugin_installer.py`, new `lib/frontmatter.py`

## Acceptance Criteria
- [ ] Shared frontmatter parser exists in lib/
- [ ] All 4-5 call sites use the shared function

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Consolidation introduced duplication while removing old module |

## Resources
- PR: #75
