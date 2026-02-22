---
status: pending
priority: p3
issue_id: 75
tags: [code-review, security, python]
dependencies: []
---

# YAML Frontmatter Injection in create_agent

## Problem Statement

`create_agent` builds YAML frontmatter via f-string interpolation. Description/model/tools values with newlines could inject arbitrary YAML keys that alter agent behavior.

## Findings

- **Source**: security-sentinel (P3, confidence 80)
- **Location**: `computer/parachute/api/agents.py:210-216`
- **Evidence**: `f"description: {body.description}"` — newlines in description inject additional YAML keys

## Proposed Solutions

### Solution A: Use yaml.safe_dump (Recommended)
Build frontmatter dict, serialize with `yaml.safe_dump()`.
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/api/agents.py`

## Acceptance Criteria
- [ ] Frontmatter generated with yaml.safe_dump
- [ ] Newlines in description/model don't inject YAML keys

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | f-string YAML is injection-prone |

## Resources
- PR: #75
