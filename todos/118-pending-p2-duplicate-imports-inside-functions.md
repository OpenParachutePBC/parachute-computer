---
status: pending
priority: p2
issue_id: 35
tags: [code-review, python, code-quality]
dependencies: []
---

# Duplicate Imports Inside Functions

## Problem Statement

Three imports (`re`, `uuid`, `datetime`) are imported inside the `create_session()` function instead of at module level. The `re` module is imported twice — once at module level (line 29) and again inside the function (line 530).

**Why it matters:** Function-level imports add overhead on hot paths and create code clutter. The duplicate `re` import is a clear bug.

## Findings

**Source:** python-reviewer agent (confidence: 100%)

**Locations:**
- `computer/parachute/mcp_server.py:530` — `import re` (duplicate of line 29)
- `computer/parachute/mcp_server.py:558` — `from datetime import datetime, timezone, timedelta` (datetime/timezone already imported at line 32)
- `computer/parachute/mcp_server.py:568` — `import uuid` (should be at module level)

```python
# Line 29 (module level)
import re

# Line 530 (inside create_session) — DUPLICATE
import re
if not re.match(r'^[a-zA-Z0-9_-]+$', agent_type):

# Line 558 (inside create_session)
from datetime import datetime, timezone, timedelta  # datetime/timezone already at line 32

# Line 568 (inside create_session)
import uuid
session_id = f"sess_{uuid.uuid4().hex[:16]}"
```

**Impact:**
- Import overhead on every `create_session()` call (minimal but unnecessary)
- Code clutter and maintenance confusion
- Violates Python style guide (PEP 8: imports at top)

## Proposed Solutions

### Option 1: Move All Imports to Module Level (Recommended)
**Effort:** Small (2 minutes)
**Risk:** None

```python
# Add to module-level imports (after line 32)
import uuid
from datetime import datetime, timezone, timedelta

# Remove lines 530, 558, 568 from create_session function
```

**Pros:**
- Standard Python practice
- Zero overhead
- Eliminates duplicate

**Cons:**
- None

## Recommended Action

**Move imports to module level** — This is a straightforward code quality fix.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py`

**Changes:**
1. Remove line 530 (`import re` duplicate)
2. Add `timedelta` to line 32 import: `from datetime import datetime, timezone, timedelta`
3. Remove line 558 (duplicate datetime import)
4. Add `import uuid` to module-level imports
5. Remove line 568 (`import uuid`)

## Acceptance Criteria

- [ ] All imports at module level (no function-level imports)
- [ ] No duplicate `re` import
- [ ] `timedelta` added to existing datetime import
- [ ] `uuid` imported at module level
- [ ] Code passes linting (flake8/ruff)

## Work Log

- 2026-02-22: Identified during code review by python-reviewer agent

## Resources

- **PEP 8:** https://peps.python.org/pep-0008/#imports
- **Source PR:** feat/multi-agent-workspace-teams branch
