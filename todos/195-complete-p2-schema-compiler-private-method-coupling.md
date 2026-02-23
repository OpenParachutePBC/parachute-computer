---
status: complete
priority: p2
issue_id: "195"
tags: [code-review, python, brain, architecture]
dependencies: []
---

# KnowledgeGraphService calls SchemaCompiler private methods (_compile_field, _build_key_strategy)

## Problem Statement
`KnowledgeGraphService._compile_field_from_spec()` calls `SchemaCompiler()._compile_field()` and `SchemaCompiler()._build_key_strategy()` — both are private (_-prefixed) methods. Cross-class access to private methods creates inappropriate coupling. If `SchemaCompiler` refactors its internals, callers break without API signal.

## Findings
- knowledge_graph.py:464-466 — direct call to `SchemaCompiler()._compile_field`
- knowledge_graph.py:494-496 — direct call to `SchemaCompiler()._build_key_strategy`
- Architecture reviewer confidence 80

## Proposed Solutions
### Option 1: Add public API to SchemaCompiler
Add public `compile_field_from_spec(field_spec: FieldSpec, ...)` and `build_key_strategy(strategy: str)` methods to `SchemaCompiler`. `KnowledgeGraphService` calls public interface only.

## Recommended Action

## Technical Details
**Affected files:**
- computer/modules/brain/knowledge_graph.py:464-466
- computer/modules/brain/knowledge_graph.py:494-496

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] No cross-class calls to _-prefixed methods
- [ ] `SchemaCompiler` has public API for field compilation

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
