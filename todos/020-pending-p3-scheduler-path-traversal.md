---
status: pending
priority: p3
issue_id: "30"
tags: [code-review, computer, security, pre-existing]
dependencies: []
---

# Agent name path traversal in scheduler endpoint (pre-existing)

## Problem Statement

The `POST /scheduler/agents/{agent_name}/trigger` endpoint passes user-controlled `agent_name` directly to `get_daily_agent_config()`, which constructs a file path. A value like `../../etc/passwd` could resolve outside the intended directory. Exploitability is limited (file must end in `.md` and parse as valid YAML frontmatter).

## Findings

- Discovered by: security-sentinel
- Location: `computer/parachute/api/scheduler.py:60`
- Pre-existing issue, NOT introduced by this PR
- Limited exploitability due to `.md` extension and YAML parse requirements

## Proposed Solutions

### Option A: Add regex guard (Recommended)
- Add `if not re.match(r'^[a-zA-Z0-9_-]+$', agent_name): raise HTTPException(400)`
- Effort: Small
- Risk: Low
