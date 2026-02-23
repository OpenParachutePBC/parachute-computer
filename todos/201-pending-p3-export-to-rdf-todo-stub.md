---
status: pending
priority: p3
issue_id: "201"
tags: [code-review, python, brain, cleanup, yagni]
dependencies: []
---

# export_to_rdf() is a TODO stub with no implementation and no callers — remove it

## Problem Statement
`knowledge_graph.py:749-752` contains:

```python
async def export_to_rdf(self, output_path: Path) -> None:
    # TODO: Phase 2 - implement RDF export
    pass
```

The method has no implementation, no callers anywhere in the codebase, and no tests. It is pure YAGNI — the "Phase 2" note suggests it was added speculatively rather than when needed.

## Findings
- `knowledge_graph.py:749-752` — empty async stub with TODO comment
- No callers found anywhere in the codebase
- No tests exist for this method
- Simplicity reviewer flags as YAGNI

## Proposed Solutions
### Option 1: Delete the method
Remove the four lines comprising `export_to_rdf`. Re-add when RDF export is actually being implemented, at which point a proper design can be made.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:749-752

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `export_to_rdf` method is removed from `knowledge_graph.py`
- [ ] No references to `export_to_rdf` remain in the codebase

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
