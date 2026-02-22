---
status: pending
priority: p1
issue_id: 100
tags: [code-review, flutter, performance, memory-leak]
dependencies: []
---

# Memory Leak: Missing autoDispose on Entity Detail Provider

## Problem Statement

The `brainV2EntityDetailProvider` in `brain_v2_entity_providers.dart` is missing `.autoDispose`, which causes memory leaks. When users navigate away from entity detail screens, the provider instances remain in memory indefinitely, accumulating HTTP clients, cached data, and listeners. This is critical because each entity detail view creates a new provider instance that never gets cleaned up.

**Impact**: Memory grows unbounded as users browse entities, eventually degrading app performance and potentially causing crashes on memory-constrained devices.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 95
**Location**: `app/lib/features/brain_v2/providers/brain_v2_entity_providers.dart:19-20`

Current implementation:
```dart
final brainV2EntityDetailProvider =
    FutureProvider.family<BrainV2Entity?, String>((ref, id) async {
```

**Evidence**: FutureProvider.family instances without autoDispose persist for the lifetime of the ProviderContainer. With entity IDs as family parameters, each viewed entity creates a permanent cache entry.

## Proposed Solutions

### Option 1: Add autoDispose (Recommended)
**Implementation**:
```dart
final brainV2EntityDetailProvider =
    FutureProvider.autoDispose.family<BrainV2Entity?, String>((ref, id) async {
```

**Pros**:
- One-line fix
- Automatic cleanup when no longer watched
- Standard Riverpod pattern for transient data
- No behavior changes for users

**Cons**:
- Data refetched if user returns to same entity (acceptable for freshness)

**Effort**: Small (1 minute)
**Risk**: Very Low

### Option 2: Manual keepAlive with disposal logic
**Implementation**:
```dart
final brainV2EntityDetailProvider =
    FutureProvider.autoDispose.family<BrainV2Entity?, String>((ref, id) async {
  final link = ref.keepAlive();
  Timer(const Duration(minutes: 5), link.close);
  // ... existing logic
```

**Pros**:
- Caches data for 5 minutes
- Reduces redundant fetches for back navigation

**Cons**:
- More complex
- Still accumulates memory over time
- Requires timer management

**Effort**: Medium (15 minutes)
**Risk**: Low

### Option 3: Shared cache with LRU eviction
**Implementation**: Create a separate caching layer with size limits

**Pros**:
- Full control over cache size
- Optimal for large entity sets

**Cons**:
- Significant complexity
- Overkill for current needs

**Effort**: Large (2+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/providers/brain_v2_entity_providers.dart` (line 19)

**Affected Components**:
- BrainV2EntityDetailScreen
- BrainV2RelationshipChip (uses provider indirectly)
- Any widget watching this provider

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] Provider definition includes `.autoDispose`
- [ ] No memory leaks when navigating entity list → detail → back (verified with DevTools)
- [ ] Entity detail screen still loads correctly
- [ ] Related entity chips still load correctly
- [ ] No performance regressions in entity browsing

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Missing autoDispose pattern on FutureProvider.family
- **Source**: flutter-reviewer agent (confidence: 95)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Riverpod Docs**: https://riverpod.dev/docs/concepts/modifiers/auto_dispose
- **Similar Pattern**: See `brainV2EntityListProvider` (correct usage with autoDispose)
