---
status: complete
priority: p2
issue_id: 40
tags: [code-review, security, prompt]
dependencies: []
---

# Absolute Vault Path Exposed in System Prompt Text

## Problem Statement

The working directory framing block embeds `self.vault_path` (an absolute filesystem path like `/Users/aaron/Parachute`) directly into the system prompt text sent to the AI model. This contradicts the PR's own stated goal of "never expose absolute paths" and the metadata fallback fix that was made in the same PR.

## Findings

- **Source**: python-reviewer, code-simplicity-reviewer, agent-native-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist (5 of 9 agents flagged this)
- **Location**: `computer/parachute/core/orchestrator.py:1344`
- **Evidence**: `f"(within the Parachute vault at {self.vault_path})\n"` embeds the raw absolute path
- **Context**: The metadata fallback at line 1406 was specifically fixed to use `md_path.name` to avoid path disclosure, but the framing text introduces the same category of disclosure

## Proposed Solutions

### Solution A: Remove vault path entirely (Recommended)
Replace with a generic label since the AI already knows the vault path from SDK's `cwd` parameter.
```python
f"(within the Parachute vault)\n"
```
- **Pros**: Simplest fix, consistent with "never expose absolute paths" principle
- **Cons**: Slightly less context for the AI (but SDK already provides `cwd`)
- **Effort**: Small (1 line)
- **Risk**: Low

### Solution B: Use tilde-relative path
```python
vault_display = f"~/{self.vault_path.relative_to(Path.home())}" if self.vault_path.is_relative_to(Path.home()) else "the Parachute vault"
```
- **Pros**: Preserves useful context without full absolute path
- **Cons**: More code, `Path.home()` call, extra error handling
- **Effort**: Small
- **Risk**: Low

## Recommended Action

Solution A — the SDK already passes the absolute path via `cwd`, so the AI has the information it needs. No reason to duplicate it in prompt text.

## Technical Details

- **Affected files**: `computer/parachute/core/orchestrator.py`
- **Line**: 1344

## Acceptance Criteria

- [ ] `self.vault_path` no longer appears in the system prompt text
- [ ] Working directory framing still communicates the vault-relative path
- [ ] Prompt preview API reflects the change

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Identified during PR #40 review by 5 agents | Consistent finding across security, simplicity, agent-native, conventions, and pattern reviews |

## Resources

- PR: #40
- Issue: #18
