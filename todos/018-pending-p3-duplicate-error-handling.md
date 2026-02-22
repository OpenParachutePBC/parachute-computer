---
status: pending
priority: p3
issue_id: 100
tags: [code-review, code-quality, duplication]
dependencies: []
---

# Duplicate Error Handling: Repeated Patterns Across Screens

## Problem Statement

Error handling logic is duplicated across entity list, detail, and form screens. Each screen has nearly identical error UI (red icon, error message, retry button) with copy-pasted code.

**Impact**: Minor. Code duplication makes maintenance harder. Inconsistent error messages. Future changes require updating multiple locations.

## Findings

**Source**: code-simplicity-reviewer agent
**Confidence**: 68
**Locations**:
- `brain_v2_entity_list_screen.dart:95-128`
- `brain_v2_entity_form_screen.dart:70-84`
- `brain_v2_home_screen.dart:79-94`

**Evidence**:

```dart
// Duplicated in 3+ locations
error: (error, stack) => Center(
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
      const SizedBox(height: 16),
      Text('Failed to load ...'),  // ← Only difference
      const SizedBox(height: 8),
      Text(error.toString(), ...),
      const SizedBox(height: 16),
      ElevatedButton(
        onPressed: () => ref.invalidate(...),  // ← Only difference
        child: const Text('Retry'),
      ),
    ],
  ),
),
```

**Duplication Stats**:
- ~50 lines of duplicated error UI code
- 3 nearly identical implementations
- Only differences: error message text, retry callback

## Proposed Solutions

### Option 1: Extract ErrorView widget (Recommended)
**Implementation**:

```dart
// lib/core/widgets/error_view.dart
class ErrorView extends StatelessWidget {
  final String title;
  final Object error;
  final VoidCallback? onRetry;
  final String? retryLabel;

  const ErrorView({
    required this.title,
    required this.error,
    this.onRetry,
    this.retryLabel = 'Retry',
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Colors.red[isDark ? 300 : 700],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: TextStyle(
              fontSize: 14,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onRetry,
              child: Text(retryLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

// Usage
error: (error, stack) => ErrorView(
  title: 'Failed to load entities',
  error: error,
  onRetry: () => ref.invalidate(brainV2EntityListProvider(widget.entityType)),
),
```

**Pros**:
- DRY (Don't Repeat Yourself)
- Consistent error UI
- Easy to update globally
- Reduces code by ~40 lines

**Cons**:
- Another widget to maintain

**Effort**: Small (1-2 hours)
**Risk**: Very Low

### Option 2: Use existing error handling package
**Implementation**: Add flutter_error_boundary or similar

**Pros**:
- Battle-tested
- Feature-rich

**Cons**:
- External dependency
- Learning curve
- Overkill for simple use case

**Effort**: Medium (2-3 hours)
**Risk**: Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/widgets/error_view.dart`
- Modify: `brain_v2_entity_list_screen.dart` (replace error handler)
- Modify: `brain_v2_entity_form_screen.dart` (replace error handler)
- Modify: `brain_v2_home_screen.dart` (replace error handler)
- Modify: `brain_v2_entity_detail_screen.dart` (replace error handler)

**Code Reduction**:
- Before: ~150 lines of duplicated error UI
- After: ~50 lines (1 widget + 4 usages)
- Savings: ~100 lines

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] ErrorView widget created and documented
- [ ] All error handlers use ErrorView
- [ ] Error messages still display correctly
- [ ] Retry buttons work as before
- [ ] Dark mode support maintained
- [ ] Visual regression test passes

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Duplicated error handling UI across screens
- **Source**: code-simplicity-reviewer agent (confidence: 68)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **DRY Principle**: https://en.wikipedia.org/wiki/Don%27t_repeat_yourself
