---
status: complete
priority: p2
issue_id: "198"
tags: [code-review, python, brain, architecture, module-loader]
dependencies: []
---

# builtin_dir path resolution uses brittle parent.parent.parent chain — silent failure on layout change

## Problem Statement
module_loader.py:46 calculates `builtin_dir` via three `.parent` calls: `Path(__file__).parent.parent.parent / "modules"`. Works for current layout but breaks silently if package is installed via pip or directory layout changes. If `builtin_dir` doesn't exist, the loader silently loads zero built-in modules with only INFO-level absence of output.

## Findings
- module_loader.py:46 — `Path(__file__).parent.parent.parent / "modules"` path arithmetic
- Architecture reviewer confidence 88, Parachute conventions reviewer confidence 81
- Silent failure: loads zero built-in modules with no error logged

## Proposed Solutions
### Option 1: Add startup warning and document path arithmetic
Add explicit startup warning if `builtin_dir` exists but contains no valid modules (`logger.error`, not `logger.info`). Add comment explaining the path arithmetic. Consider deriving path from a config constant.

### Option 2: Use importlib.resources for packaging correctness
Use `importlib.resources` to locate built-in modules for packaging correctness.

## Recommended Action
Option 1 short-term (add warning + comment); Option 2 if packaging is planned.

## Technical Details
**Affected files:**
- computer/module_loader.py:46

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Server logs clear error (not silent) if `builtin_dir` resolves incorrectly
- [ ] Path arithmetic documented with comment

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
