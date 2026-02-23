---
status: pending
priority: p3
issue_id: 107
tags: [code-review, ux, credentials, system-prompt]
dependencies: []
---

# Make Credential Tool Hints Generic Instead of Hardcoded

## Problem Statement

**What's broken/missing:**
`orchestrator._build_system_prompt` hardcodes exactly 3 credential-to-tool mappings (GH_TOKEN→gh, AWS_ACCESS_KEY_ID→aws, NODE_AUTH_TOKEN→npm). Any other credential a user adds gets no discoverability hint in the system prompt.

**Why it matters:**
- A user adding DOCKER_TOKEN, ANTHROPIC_API_KEY, or any custom credential gets no hint
- Adding a new supported tool requires a code change (YAGNI violation)
- The list is artificial and will need to grow as more tools are supported

## Findings

**From code-simplicity-reviewer (Confidence: 88):**
> Replace 3-entry hardcoded map with generic key-name list. LOC delta: -8 lines, +3 lines.

## Proposed Solution

Replace the hardcoded mapping with a generic list of injected key names:

```python
cred_keys = credential_keys or set()
if cred_keys:
    append_parts.append(
        "## Injected Credentials\n\n"
        "The following environment variables are pre-set in this session: "
        + ", ".join(f"`{k}`" for k in sorted(cred_keys))
    )
```

This removes the mapping table, is forward-compatible with any credential, and still achieves discoverability. Agents can look up what tool uses each env var.

**Effort:** Small
**Risk:** Very low (cosmetic system prompt change)

## Acceptance Criteria
- [ ] All injected credential key names appear in system prompt
- [ ] No hardcoded GH_TOKEN/AWS_ACCESS_KEY_ID/NODE_AUTH_TOKEN check
- [ ] Bot sessions still receive no credential section (existing fix preserved)

## Resources
- File: `computer/parachute/core/orchestrator.py` (`_build_system_prompt`, lines ~1598-1613)
