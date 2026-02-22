---
status: pending
priority: p1
issue_id: 100
tags: [code-review, flutter, safety, async]
dependencies: []
---

# BuildContext Safety: Unsafe Context Usage After Async Operations

## Problem Statement

Multiple locations in `brain_v2_entity_detail_screen.dart` use BuildContext after async operations without checking `context.mounted`. When async operations complete after the widget is disposed (user navigates away), accessing context causes crashes or undefined behavior.

**Impact**: App crashes when users navigate away during delete operations or rapid navigation patterns. This violates Flutter's fundamental safety requirements for async context usage.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 98
**Location**: `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`

**Evidence**: Lines 358-382 in `_handleDelete` method:

```dart
// Line 366-371 - First context use is checked ✓
if (mounted) {
  Navigator.of(context).pop();
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Entity deleted successfully')),
  );
}

// Line 375-380 - Second context use is UNCHECKED ✗
if (context.mounted) {  // ← Checks mounted but still uses context unsafely
  Navigator.of(context).pop();
  ScaffoldMessenger.of(context).showSnackBar(  // ← UNSAFE
    const SnackBar(content: Text('Entity deleted successfully')),
  );
}
```

**Pattern**: The code checks `context.mounted` but then immediately uses `context` multiple times without storing the navigator/messenger references first.

## Proposed Solutions

### Option 1: Store references before async (Recommended)
**Implementation**:
```dart
Future<void> _handleDelete() async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);

  // Show confirmation dialog
  final confirmed = await showDialog<bool>(...);

  if (confirmed == true) {
    try {
      await service.deleteEntity(widget.entityId, commitMsg: commitMsg);

      ref.invalidate(brainV2EntityListProvider);

      if (mounted) {
        navigator.pop();
        messenger.showSnackBar(
          const SnackBar(content: Text('Entity deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
```

**Pros**:
- Safest pattern - captures context-dependent objects before async
- No redundant mounted checks
- Standard Flutter best practice
- Works even if widget is disposed

**Cons**: None

**Effort**: Small (10 minutes)
**Risk**: Very Low

### Option 2: Check mounted before each context use
**Implementation**:
```dart
if (mounted) {
  Navigator.of(context).pop();
}
if (mounted) {
  ScaffoldMessenger.of(context).showSnackBar(...);
}
```

**Pros**:
- Simple to understand
- Explicit safety checks

**Cons**:
- Redundant checks
- Verbose
- Can still fail if widget disposes between checks (race condition)

**Effort**: Small (10 minutes)
**Risk**: Low

### Option 3: Use navigatorKey and messengerKey
**Implementation**: Add GlobalKeys to widget state

**Pros**:
- Works without context
- No mounted checks needed

**Cons**:
- Adds state complexity
- Overkill for this use case
- Non-standard pattern in this codebase

**Effort**: Medium (30 minutes)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart` (lines 358-382)

**Affected Components**:
- BrainV2EntityDetailScreen._handleDelete method
- Delete confirmation flow
- Post-delete navigation and feedback

**Similar Issues**: Check other async methods in same file:
- `_handleSubmit` (form submission)
- Any other methods using `Navigator.of(context)` or `ScaffoldMessenger.of(context)` after await

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All Navigator.of(context) and ScaffoldMessenger.of(context) calls use pre-captured references
- [ ] No context access after async gaps without proper safety
- [ ] Delete flow works correctly when user navigates away during operation
- [ ] No crashes when rapidly navigating between entity screens
- [ ] Manual testing: Delete entity, navigate away immediately - no crash
- [ ] Flutter analyzer shows no warnings about unsafe context usage

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Multiple unsafe context usages after async operations
- **Source**: flutter-reviewer agent (confidence: 98)
- **Pattern**: Common Flutter anti-pattern that causes production crashes

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Flutter Docs**: https://api.flutter.dev/flutter/widgets/State/mounted.html
- **Best Practice**: https://dart.dev/tools/linter-rules/use_build_context_synchronously
- **Location**: `brain_v2_entity_detail_screen.dart:358-382`
