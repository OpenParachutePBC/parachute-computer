---
status: pending
priority: p3
issue_id: 40
tags: [code-review, quality]
dependencies: []
---

# Duplicated Path Resolution in `_build_system_prompt()`

## Problem Statement

The `working_directory` string is resolved to an absolute `Path` twice in `_build_system_prompt()` with different variable names (`wd_path` at line 1332 and `working_dir_path` at line 1394). Both blocks do the identical `is_absolute()` check and `vault_path / working_directory` construction.

## Findings

- **Source**: pattern-recognition-specialist, code-simplicity-reviewer
- **Location**: `computer/parachute/core/orchestrator.py:1332-1334` and `1394-1396`
- **Note**: Both reviewers concluded the duplication is acceptable since the blocks serve different purposes (prompt text vs metadata) and are separated by ~60 lines. Extracting would require a wider variable scope that may reduce clarity.

## Proposed Solutions

### Solution A: Leave as-is (Recommended by reviewers)
The duplication is 3 lines, trivial, and each block is self-contained.
- **Effort**: None
- **Risk**: None

### Solution B: Extract to local variable
Compute once before both blocks and reuse.
- **Pros**: DRY principle
- **Cons**: Introduces wider variable scope, may reduce locality of reasoning
- **Effort**: Small
- **Risk**: Low

## Recommended Action

Leave as-is for now. The self-contained nature of each block is a readability benefit.

## Resources

- PR: #40
