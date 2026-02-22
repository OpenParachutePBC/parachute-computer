---
status: pending
priority: p2
issue_id: 100
tags: [code-review, flutter, deprecation, technical-debt]
dependencies: []
---

# Deprecated ScaffoldMessenger API: Direct of(context) Usage

## Problem Statement

Multiple screens use `ScaffoldMessenger.of(context)` which is deprecated in favor of `ScaffoldMessenger.maybeOf(context)` with null checking. The deprecated API can throw exceptions when called in contexts without an ancestor Scaffold, and doesn't provide type-safe null handling.

**Impact**: Potential crashes in edge cases where Scaffold isn't available. Technical debt that will require fixes in future Flutter versions. Linter warnings clutter the build output.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 85
**Locations**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart`
- Multiple showSnackBar calls

**Evidence**:
```dart
// Deprecated pattern (multiple locations)
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text('Message')),
);
```

Should be:
```dart
// Preferred pattern
ScaffoldMessenger.maybeOf(context)?.showSnackBar(
  SnackBar(content: Text('Message')),
);
```

## Proposed Solutions

### Option 1: Replace all with maybeOf (Recommended)
**Implementation**:
```dart
// Find all instances
grep -r "ScaffoldMessenger.of(context)" app/lib/features/brain_v2/

// Replace with null-safe version
ScaffoldMessenger.maybeOf(context)?.showSnackBar(
  SnackBar(content: Text('Message')),
);
```

**Pros**:
- Null-safe
- Removes deprecation warnings
- Future-proof
- No behavior change in normal cases

**Cons**: None

**Effort**: Small (30 minutes)
**Risk**: Very Low

### Option 2: Pre-capture messenger reference
**Implementation**:
```dart
// In async methods, capture before async gap
final messenger = ScaffoldMessenger.maybeOf(context);
// ... async operations
messenger?.showSnackBar(...);
```

**Pros**:
- More robust for async operations
- Combines with BuildContext safety fix (#003)

**Cons**:
- More code changes
- Different pattern

**Effort**: Small (30 minutes, combined with #003)
**Risk**: Very Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart`
- Any screen with SnackBar feedback

**Flutter Version**: Deprecated in Flutter 2.5+, warning level increased in 3.x

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All ScaffoldMessenger.of(context) replaced with maybeOf
- [ ] No deprecation warnings in build output
- [ ] SnackBars still display correctly in all flows
- [ ] Null checks prevent crashes in edge cases
- [ ] Grep shows zero instances of deprecated pattern

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Deprecated ScaffoldMessenger API usage
- **Source**: flutter-reviewer agent (confidence: 85)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Flutter Docs**: https://api.flutter.dev/flutter/material/ScaffoldMessenger/maybeOf.html
- **Migration Guide**: https://docs.flutter.dev/release/breaking-changes/scaffold-messenger
