---
status: pending
priority: p3
issue_id: 62
tags: [code-review, documentation, git-history]
created: 2026-02-21
---

# Trust Level Rename Lacks Git History Context Documentation

## Problem Statement

The trust level rename (trusted→direct, untrusted→sandboxed) in commit 8f93d13 successfully updates all code and migrations, but doesn't document:

1. **Why** the rename happened (what was confusing about old names?)
2. **Historical context** for future developers encountering legacy code
3. **Lessons learned** about naming conventions
4. **Migration strategy** that was chosen and why

Without this context, future developers might:
- Not understand why both `TRUSTED` and `DIRECT` exist in the enum
- Question the migration v16 logic
- Repeat similar naming mistakes

**Impact:** Low - Code works correctly, but loses institutional knowledge.

**Introduced in:** Commit 8f93d13

## Findings

**Source:** Git History Analyzer (Confidence: 83)

**What commit 8f93d13 includes:**
- ✅ Code changes (trust.py, migrations, models)
- ✅ Database migration v16
- ✅ Backward compatibility (legacy aliases)
- ✅ Comprehensive test updates

**What's missing:**
- ❌ No design doc explaining rationale for rename
- ❌ No comment in trust.py explaining old vs new names
- ❌ No migration guide for external consumers (if any)

**From commit message:**
```
feat(sandbox): trust level rename + default container + per-session scratch dirs

Phase 1 of workspace & sandbox rework. Three main chunks:

1. Trust level rename: trusted→direct, untrusted→sandboxed
   - Clearer semantics (direct=unrestricted, sandboxed=container)
   - Legacy aliases maintained for backward compat
   - Migration v16 updates existing data
```

This is good, but doesn't explain *why* "direct" and "sandboxed" are clearer.

## Proposed Solutions

### Solution 1: Add Historical Context Comment to trust.py (Recommended)

**Approach:** Document the naming evolution inline where trust levels are defined.

**Implementation:**
```python
# computer/parachute/core/trust.py
"""
Trust level definitions and normalization.

## Trust Level Naming History

### Original names (pre-8f93d13):
- **trusted** - Unrestricted code execution on host
- **untrusted** - Docker sandboxed execution

### Why we renamed (8f93d13, 2026-02-21):
The original names were ambiguous:
- "trusted" didn't clarify WHAT was trusted (the code? the user? the vault?)
- "untrusted" was negative framing (what it ISN'T vs what it IS)
- Users asked: "trusted by whom?" and "what makes code trusted?"

### Current names (8f93d13+):
- **direct** - Execution directly on host (no Docker isolation)
- **sandboxed** - Execution in Docker container with restrictions

Improvements:
- Describes the execution MODEL not a trust judgment
- Positive framing (what it IS, not what it lacks)
- Clear implementation detail (direct=host, sandboxed=container)

### Legacy aliases:
We maintain backward compatibility for old code and configs:
- `trusted` → `direct`
- `untrusted` → `sandboxed`
- `full` → `direct` (very old alias)
- `vault` → `direct` (very old alias)

See migration v16 in db/database.py for data migration.
"""

TrustLevelStr = Literal["direct", "sandboxed"]
```

**Pros:**
- Documents design decision inline
- Explains rationale for future developers
- Preserves institutional knowledge
- Located exactly where trust levels are defined

**Cons:**
- Verbose (but that's appropriate for design context)

**Effort:** Small (30 minutes)
**Risk:** None

### Solution 2: Create Design Doc in docs/

**Approach:** Write a separate ADR (Architecture Decision Record) explaining the rename.

**Implementation:**
Create `docs/architecture/adr-001-trust-level-rename.md`:
```markdown
# ADR-001: Trust Level Naming Convention

**Date:** 2026-02-21
**Status:** Accepted
**Commit:** 8f93d13

## Context

Parachute uses trust levels to control agent execution environments. Originally:
- `trusted` - unrestricted host execution
- `untrusted` - Docker sandboxed execution

### Problems with Original Naming

1. **Ambiguous trust subject** - "trusted" doesn't specify WHO trusts WHAT
2. **Negative framing** - "untrusted" describes what something lacks, not what it is
3. **User confusion** - Multiple users asked "trusted by whom?" and "how does code become trusted?"
4. **Implementation-agnostic** - Names don't hint at execution model

## Decision

Rename trust levels to describe execution model:
- `trusted` → `direct` (direct host execution)
- `untrusted` → `sandboxed` (Docker container execution)

### Rationale

- **direct** clearly indicates no isolation layer (direct=host)
- **sandboxed** clearly indicates container isolation
- Both are positive framing (what they ARE)
- Names describe implementation, not judgment
- More intuitive for new users

## Implementation

- Migration v16 updates database
- Legacy aliases maintained for backward compat
- Python and Flutter enums updated
- MCP trust filtering updated

## Consequences

**Positive:**
- Clearer user-facing terminology
- Less confusion about trust model
- Better alignment with implementation

**Negative:**
- Breaking change (mitigated by legacy aliases)
- Existing docs/code/configs need updates
- Two names for same concept during transition period
```

**Pros:**
- Formal ADR structure
- Discoverable in docs/architecture/
- Follows ADR best practices

**Cons:**
- Separate file (less likely to be found when reading code)
- More formal than necessary for this decision

**Effort:** Medium (1 hour)
**Risk:** None

### Solution 3: Expand Commit Message (Retroactive)

**Approach:** Use `git notes` to add extended context to commit 8f93d13.

**Pros:**
- Attached directly to commit
- Visible in git log

**Cons:**
- `git notes` not widely used
- Requires fetching notes separately
- Doesn't help code readers

**Effort:** Small (15 minutes)
**Risk:** Low

## Recommended Action

Implement **Solution 1** - add comprehensive historical context comment to `trust.py`. This is the most discoverable location since anyone working with trust levels will read this file.

Optionally consider Solution 2 (ADR) if you want formal architecture decision tracking.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/core/trust.py` (add docstring)

**Components:**
- Trust level definitions
- Historical documentation

**Database changes:** None

## Acceptance Criteria

- [ ] Add module docstring to `trust.py` explaining naming history
- [ ] Document original names (trusted/untrusted)
- [ ] Explain why they were renamed
- [ ] Document current names (direct/sandboxed)
- [ ] List improvements from rename
- [ ] Document legacy aliases and backward compat
- [ ] Reference migration v16

## Work Log

- **2026-02-21**: Issue identified during git history analysis of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename

**Architecture Decision Records (ADR) pattern:**
- https://adr.github.io/
- Lightweight documentation of design decisions
