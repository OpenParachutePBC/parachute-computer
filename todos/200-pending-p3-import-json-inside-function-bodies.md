---
status: pending
priority: p3
issue_id: "200"
tags: [code-review, python, brain, style]
dependencies: []
---

# import json/uuid inside function bodies in mcp_tools.py — move to file top

## Problem Statement
`import json` appears 4 times inside handler function bodies in `mcp_tools.py` (lines 598, 621, 637, 659). `import uuid as uuid_mod` appears once inside a function body as well. Both are stdlib modules with no circular import risk. Function-level imports add cognitive overhead and make the import surface of the module non-obvious, with no compensating benefit.

## Findings
- `mcp_tools.py:598` — `import json` inside function body
- `mcp_tools.py:621` — `import json` inside function body
- `mcp_tools.py:637` — `import json` inside function body
- `mcp_tools.py:659` — `import json` inside function body
- `mcp_tools.py` (approx line near above) — `import uuid as uuid_mod` inside function body
- Simplicity reviewer confidence: 80

## Proposed Solutions
### Option 1: Move to file top
Add `import json` and `import uuid` to the top-level import block at the top of `mcp_tools.py`. Remove all inline import statements.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/mcp_tools.py:598
- computer/modules/brain/mcp_tools.py:621
- computer/modules/brain/mcp_tools.py:637
- computer/modules/brain/mcp_tools.py:659

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `import json` appears exactly once at the top of `mcp_tools.py`
- [ ] `import uuid` (or `import uuid as uuid_mod`) appears exactly once at the top of `mcp_tools.py`
- [ ] No `import json` or `import uuid` statements remain inside function bodies

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
