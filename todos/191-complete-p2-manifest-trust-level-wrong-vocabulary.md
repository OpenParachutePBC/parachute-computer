---
status: complete
priority: p2
issue_id: "191"
tags: [code-review, python, brain, conventions]
dependencies: []
---

# brain manifest.yaml declares trust_level: trusted — not in documented vocabulary and not enforced

## Problem Statement
manifest.yaml declares `trust_level: trusted` but the documented trust levels are `full`, `vault`, `sandboxed`. "trusted" is not in the vocabulary. Furthermore, the module_loader reads this field only for display purposes in `scan_offline_status`; it is never enforced at runtime.

## Findings
- computer/modules/brain/manifest.yaml:4 — `trust_level: trusted`
- module_loader.py:264 — read for display only, never enforced
- Parachute conventions reviewer confidence 92

## Proposed Solutions
### Option 1: Update manifest to use documented value
Update manifest to use a documented value (likely "full" for built-in direct trust). Add documentation note that built-in modules always run at caller's trust level.

### Option 2: Remove the field from built-in manifests
Remove with a comment explaining it only applies to vault modules.

## Recommended Action
Option 1.

## Technical Details
**Affected files:**
- computer/modules/brain/manifest.yaml:4
- computer/module_loader.py:264

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] All built-in module manifests use documented trust_level vocabulary
- [ ] Field value matches enforced behavior

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
