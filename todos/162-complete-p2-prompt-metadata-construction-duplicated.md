---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, cleanup, chat]
dependencies: []
---

# `PromptMetadata` construction block duplicated verbatim in reattach and sendMessage paths

## Problem Statement

The `PromptMetadata(...)` construction block is copy-pasted verbatim between the reattach stream handler (lines 716–730) and the send stream handler (lines 1430–1444) in `chat_message_providers.dart`. All 10+ fields are identical in both blocks. If `PromptMetadata` gains a new field, both locations must be updated — an easy miss that will cause one path to silently omit the new field.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence: 90)
- **Location**: `app/lib/features/chat/providers/chat_message_providers.dart:716-730` and `1430-1444`
- **Evidence**: Both blocks are byte-for-byte identical 15-line construction expressions.

## Proposed Solutions

### Solution A: Extract `_buildPromptMetadata(StreamEvent event)` helper (Recommended)
```dart
PromptMetadata _buildPromptMetadata(StreamEvent event) {
  return PromptMetadata(
    promptSource: event.promptSource ?? 'default',
    promptSourcePath: event.promptSourcePath,
    contextFiles: event.contextFiles,
    contextTokens: event.contextTokens,
    contextTruncated: event.contextTruncated,
    agentName: event.agentName,
    availableAgents: event.availableAgents,
    basePromptTokens: event.basePromptTokens,
    totalPromptTokens: event.totalPromptTokens,
    trustMode: event.trustMode,
  );
}
```
Replace both construction blocks with `_buildPromptMetadata(event)`.
- **Pros**: Single source of truth; adding a new field requires one change; mirrors existing `_formatWarningText` helper pattern
- **Cons**: None
- **Effort**: Trivial
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/providers/chat_message_providers.dart`

## Acceptance Criteria

- [ ] `PromptMetadata` construction appears exactly once in the file
- [ ] Both the reattach path and sendMessage path use the same helper

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
