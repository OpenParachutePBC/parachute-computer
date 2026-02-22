---
status: pending
priority: p3
issue_id: 50
tags: [code-review, flutter, riverpod, error-handling]
dependencies: []
---

# `Stream.error()` Not Applied to Sibling Transcription Providers

## Problem Statement

Fix 5a in PR #65 changed `streamingTranscriptionProvider` to use `Stream.error()` on init failure, but the sibling providers `interimTextProvider` and `vadActivityProvider` in the same file still return `Stream.value('')` and `Stream.value(false)` respectively on error. This creates an inconsistency where the main transcription state shows an error but interim text and VAD activity silently degrade.

## Findings

- **Source**: flutter-reviewer (85), architecture-strategist (82), pattern-recognition-specialist (84)
- **Location**: `app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart` — `interimTextProvider` (line 48), `vadActivityProvider` (line 59)
- **Evidence**: Three agents flagged the same inconsistency. However, the plan deliberately chose this approach — these providers are consumed by UI elements that don't need error states (VAD indicator shows idle, interim text shows nothing).

## Proposed Solutions

### Solution A: Accept current behavior — intentional design
The plan explicitly chose different error handling for sibling providers. VAD and interim text degrade silently because they're auxiliary displays. The primary `streamingTranscriptionProvider` shows the error.
- **Pros**: No change, matches plan intent
- **Cons**: Inconsistent pattern
- **Effort**: None
- **Risk**: Low

### Solution B: Propagate Stream.error() to siblings too
Apply `Stream.error(e, st)` to all three providers for consistency.
- **Pros**: Consistent error propagation
- **Cons**: VAD indicator and interim text would need error handling, may show unnecessary error states
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart`

## Acceptance Criteria

- [ ] Decision made: accept current asymmetry or propagate errors to siblings

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | Plan deliberately chose this approach |

## Resources

- PR: #65
- Issue: #50
