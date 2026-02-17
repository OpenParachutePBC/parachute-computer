---
status: pending
priority: p3
issue_id: 40
tags: [code-review, quality]
dependencies: []
---

# Token Count Uses `chain.total_tokens` Instead of `valid_files` Sum

## Problem Statement

After filtering to `valid_files`, the displayed token count still uses `chain.total_tokens` which is computed from all files. This is a cosmetic inconsistency — in practice the numbers match because failed reads contribute 0 tokens and empty files contribute 0 tokens.

## Findings

- **Source**: python-reviewer, pattern-recognition-specialist, performance-oracle (confirmed it's cosmetic-only)
- **Location**: `computer/parachute/core/context_folders.py:259`
- **Performance oracle confirmed**: `chain.total_tokens` only includes `total_chars` from successfully read files. Empty-content files contribute 0 chars. The mismatch is theoretical, not practical.

## Proposed Solutions

### Solution A: Use `sum(f.tokens for f in valid_files)` (Cleaner)
```python
token_count = sum(f.tokens for f in valid_files)
```
- **Pros**: Semantically consistent with `file_count = len(valid_files)`
- **Cons**: Technically unnecessary (same result in practice)
- **Effort**: Small (1 line)

### Solution B: Leave as-is
- **Pros**: Pre-existing pattern, practically accurate
- **Effort**: None

## Recommended Action

Solution A if touching the file for other fixes, otherwise leave as-is.

## Resources

- PR: #40
