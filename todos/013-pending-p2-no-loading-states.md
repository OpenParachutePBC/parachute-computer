---
status: pending
priority: p2
issue_id: 100
tags: [code-review, flutter, ux, feedback]
dependencies: []
---

# Missing Loading States: No Feedback During Operations

## Problem Statement

Delete, create, and update operations lack loading state feedback beyond button-level spinners. Users don't know if network requests are in progress, how long they'll take, or if the system is frozen. No progress indication for multi-step operations.

**Impact**: Poor perceived performance. Users may click buttons multiple times, thinking nothing happened. No way to cancel long-running operations. Uncertainty about system state.

## Findings

**Source**: pattern-recognition-specialist agent
**Confidence**: 78
**Locations**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart` (submit)
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart` (delete)
- `app/lib/features/brain_v2/providers/brain_v2_providers.dart` (fetch operations)

**Evidence**:
```dart
// Only loading feedback is disabled button
child: _isSubmitting
    ? const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
    : Text('Create ${widget.entityType}'),
```

**Missing**:
- Network request progress indication
- Operation status messages ("Saving...", "Deleting...", "Loading relationships...")
- Ability to cancel long operations
- Skeleton loaders for initial load
- Optimistic updates

## Proposed Solutions

### Option 1: Add loading overlays and status messages (Recommended)
**Implementation**:

```dart
// Create loading overlay widget
class LoadingOverlay extends StatelessWidget {
  final Widget child;
  final bool isLoading;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (isLoading)
          Container(
            color: Colors.black.withOpacity(0.3),
            child: Center(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      if (message != null) ...[
                        SizedBox(height: 16),
                        Text(message!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// Use in form screen
@override
Widget build(BuildContext context) {
  return LoadingOverlay(
    isLoading: _isSubmitting,
    message: _isEditMode ? 'Updating entity...' : 'Creating entity...',
    child: Scaffold(...),
  );
}
```

Add operation status provider:
```dart
final operationStatusProvider = StateNotifierProvider<OperationStatus, String?>((ref) {
  return OperationStatus();
});

class OperationStatus extends StateNotifier<String?> {
  OperationStatus() : super(null);

  void setStatus(String message) => state = message;
  void clear() => state = null;
}
```

**Pros**:
- Clear visual feedback
- Prevents duplicate actions
- Better perceived performance
- Professional UX

**Cons**:
- Adds overlay complexity
- Requires state management

**Effort**: Medium (3-4 hours)
**Risk**: Low

### Option 2: Skeleton loaders for initial load
**Implementation**:
```dart
// In entity list
loading: () => ListView.builder(
  itemCount: 5,
  itemBuilder: (context, index) => SkeletonCard(),
),
```

**Pros**:
- Better initial load experience
- Industry standard pattern
- Less jarring than spinner

**Cons**:
- Doesn't help with action feedback
- Additional widgets to build

**Effort**: Medium (2-3 hours)
**Risk**: Low

### Option 3: Optimistic updates
**Implementation**: Update UI immediately, rollback on error

**Pros**:
- Instant perceived performance
- Best UX when operations succeed

**Cons**:
- Complex rollback logic
- Can confuse users if operations fail
- Needs conflict resolution

**Effort**: Large (5+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/widgets/loading_overlay.dart`
- Modify: `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart`
- Modify: `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`
- Modify: `app/lib/features/brain_v2/providers/brain_v2_providers.dart`

**Operations Needing Feedback**:
- Entity creation (form submit)
- Entity update (form submit)
- Entity deletion (confirmation → delete)
- Initial entity list load
- Entity detail fetch
- Relationship loading

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] Loading overlay shows during create/update/delete operations
- [ ] Status messages indicate what operation is in progress
- [ ] Users cannot trigger duplicate operations during loading
- [ ] Skeleton loaders show during initial entity list load
- [ ] Smooth transitions between loading and loaded states
- [ ] Manual test: Create entity on slow network → clear feedback shown

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Missing loading state feedback for operations
- **Source**: pattern-recognition-specialist agent (confidence: 78)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **UX Patterns**: https://uxdesign.cc/the-ultimate-guide-to-proper-use-of-animation-in-ux-10bd98614fa9
- **Skeleton Loaders**: https://pub.dev/packages/shimmer
