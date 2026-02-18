---
status: pending
priority: p3
issue_id: 55
tags: [code-review, performance, python, bot-connector]
dependencies: []
---

# Unbounded _chat_locks Dictionary Growth

## Problem Statement

`BotConnector._get_chat_lock()` creates an `asyncio.Lock()` per `chat_id` and stores it in `self._chat_locks`. Over time, if many unique chat IDs send messages, this dict grows without bound. For a personal bot with few users this is negligible, but it's a latent issue.

## Findings

- **Source**: performance-oracle (confidence 88)
- **Location**: `computer/parachute/connectors/base.py` — `_get_chat_lock()` method
- **Evidence**: Dict only grows, never prunes. Each Lock is ~few hundred bytes, so practical impact is minimal for expected usage (< 100 chats).

## Proposed Solutions

### Solution A: Accept current behavior (Recommended for now)
For a personal-use bot with handful of chats, this is not a real issue. Document as known limitation.
- **Pros**: No code change needed
- **Cons**: Technically unbounded
- **Effort**: None
- **Risk**: None for expected usage

### Solution B: LRU-style eviction
Use an OrderedDict and evict oldest locks when size exceeds a threshold.
- **Pros**: Bounded memory
- **Cons**: Over-engineering for personal bot
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/base.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] Acknowledged as known limitation or bounded

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | Low practical impact for personal bot |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
