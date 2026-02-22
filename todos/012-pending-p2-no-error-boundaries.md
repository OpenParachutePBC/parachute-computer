---
status: pending
priority: p2
issue_id: 100
tags: [code-review, flutter, error-handling, resilience]
dependencies: []
---

# Missing Error Boundaries: Widget Tree Crashes Propagate

## Problem Statement

Brain v2 screens lack error boundary widgets, so exceptions in child widgets cause the entire screen to crash with a red error screen. Users lose all context and must restart navigation.

**Impact**: Poor user experience when individual components fail. A single malformed entity or relationship can crash the entire entity list/detail view. No graceful degradation for partial failures.

## Findings

**Source**: architecture-strategist agent
**Confidence**: 82
**Locations**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart`
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart`
- `app/lib/features/brain_v2/widgets/brain_v2_entity_card.dart`

**Evidence**:
No error boundary wrapper around:
- Entity card list items
- Relationship chips
- Field widgets
- Form inputs

**Example Failure Scenario**:
```dart
// If one entity has malformed data
BrainV2EntityCard(entity: malformedEntity)  // Throws
// → Entire ListView crashes
// → User sees red error screen
// → Cannot view ANY entities
```

Better approach:
```dart
ErrorBoundary(
  child: BrainV2EntityCard(entity: entity),
  fallback: (error) => Card(
    child: Text('Failed to load entity: ${error.message}'),
  ),
)
```

## Proposed Solutions

### Option 1: Add ErrorBoundary widget wrapper (Recommended)
**Implementation**:

Create reusable error boundary:
```dart
// lib/core/widgets/error_boundary.dart
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(Object error, StackTrace? stack)? fallback;

  const ErrorBoundary({
    required this.child,
    this.fallback,
    super.key,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stackTrace;

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return widget.fallback?.call(_error!, _stackTrace) ??
          _DefaultErrorWidget(error: _error!);
    }

    return ErrorWidget.builder = (details) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _error = details.exception;
            _stackTrace = details.stack;
          });
        }
      });
      return const SizedBox.shrink();
    };

    return widget.child;
  }
}
```

Use in entity list:
```dart
itemBuilder: (context, index) {
  final entity = filteredEntities[index];
  return ErrorBoundary(
    fallback: (error, _) => Card(
      child: ListTile(
        leading: Icon(Icons.error, color: Colors.red),
        title: Text('Failed to load entity'),
        subtitle: Text(error.toString(), maxLines: 2),
      ),
    ),
    child: BrainV2EntityCard(entity: entity, schema: widget.schema),
  );
}
```

**Pros**:
- Isolates failures to individual items
- Graceful degradation
- Better user experience
- Reusable across app

**Cons**:
- Additional widget wrapper overhead

**Effort**: Medium (2-3 hours)
**Risk**: Low

### Option 2: Try-catch in build methods
**Implementation**:
```dart
@override
Widget build(BuildContext context) {
  try {
    return _buildEntityCard();
  } catch (e) {
    return _buildErrorCard(e);
  }
}
```

**Pros**:
- Simple
- No new widgets

**Cons**:
- Doesn't catch errors in child widgets
- Violates separation of concerns
- Repetitive code

**Effort**: Medium (1-2 hours)
**Risk**: Low

### Option 3: Global error handler only
**Implementation**: Rely on Flutter's global ErrorWidget.builder

**Pros**:
- Already exists
- No code changes

**Cons**:
- Shows ugly red screen
- No graceful degradation
- Poor UX

**Effort**: Small (0 hours)
**Risk**: High (bad UX)

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/widgets/error_boundary.dart`
- Modify: `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart` (wrap cards)
- Modify: `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart` (wrap field widgets)
- Modify: `app/lib/features/brain_v2/widgets/brain_v2_field_widget.dart` (wrap relationship chips)

**Error Scenarios to Handle**:
- Malformed entity data
- Missing required fields
- Type mismatches
- Failed JSON parsing
- Null reference exceptions

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] ErrorBoundary widget created and documented
- [ ] Entity list wraps each card in error boundary
- [ ] Entity detail wraps each field/section in error boundary
- [ ] Fallback UI shows helpful error message
- [ ] Manual test: Inject malformed entity → shows error card, other entities load
- [ ] No full-screen crashes for individual item failures

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: No error boundaries for graceful degradation
- **Source**: architecture-strategist agent (confidence: 82)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Error Handling**: https://docs.flutter.dev/testing/errors
- **ErrorWidget**: https://api.flutter.dev/flutter/widgets/ErrorWidget-class.html
