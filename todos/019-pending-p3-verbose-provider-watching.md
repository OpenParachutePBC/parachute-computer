---
status: pending
priority: p3
issue_id: 100
tags: [code-review, code-quality, readability]
dependencies: []
---

# Verbose Provider Watching: Repeated ref.watch Patterns

## Problem Statement

Many widgets watch the same providers multiple times or use verbose patterns for accessing provider data. This makes code harder to read and maintain.

**Impact**: Minor. Slightly harder to read and maintain. No functional issues. Opportunity for cleanup.

## Findings

**Source**: code-simplicity-reviewer agent
**Confidence**: 65
**Examples**:

```dart
// brain_v2_entity_detail_screen.dart
final isDark = Theme.of(context).brightness == Brightness.dark;  // ← Repeated in every widget
final entityAsync = ref.watch(brainV2EntityDetailProvider(widget.entityId));
final service = ref.watch(brainV2ServiceProvider);

// brain_v2_form_builder.dart
final isDark = Theme.of(context).brightness == Brightness.dark;  // ← Duplicated

// brain_v2_entity_list_screen.dart
final entitiesAsync = ref.watch(brainV2EntityListProvider(widget.entityType));
final searchQuery = ref.watch(brainV2SearchQueryProvider);
```

**Patterns**:
- `Theme.of(context).brightness == Brightness.dark` appears in every widget
- Service provider watching could use helper
- AsyncValue handling is verbose

## Proposed Solutions

### Option 1: Extract theme helper and common patterns (Recommended)
**Implementation**:

```dart
// lib/core/extensions/build_context_extensions.dart
extension ThemeExtensions on BuildContext {
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  ThemeData get theme => Theme.of(this);

  TextTheme get textTheme => Theme.of(this).textTheme;

  ColorScheme get colorScheme => Theme.of(this).colorScheme;
}

// Usage
@override
Widget build(BuildContext context) {
  final isDark = context.isDarkMode;  // ← Much cleaner
  // ...
}
```

Provider helper:
```dart
// lib/core/providers/provider_helpers.dart
extension AsyncValueExtensions<T> on AsyncValue<T> {
  Widget build({
    required Widget Function(T data) data,
    Widget Function()? loading,
    Widget Function(Object error, StackTrace? stack)? error,
  }) {
    return when(
      data: data,
      loading: loading ?? () => const Center(child: CircularProgressIndicator()),
      error: error ?? (err, stack) => ErrorView(
        title: 'Error',
        error: err,
      ),
    );
  }
}

// Usage
return entityAsync.build(
  data: (entity) => _buildEntityDetail(entity),
);
```

**Pros**:
- Cleaner code
- Less repetition
- Reusable patterns

**Cons**:
- Slightly more abstraction

**Effort**: Small (2-3 hours)
**Risk**: Very Low

### Option 2: Use Riverpod hooks
**Implementation**: Add hooks_riverpod package

**Pros**:
- Cleaner state management
- Less boilerplate

**Cons**:
- Additional dependency
- Learning curve
- Larger refactor

**Effort**: Large (6+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/extensions/build_context_extensions.dart`
- Create: `app/lib/core/extensions/async_value_extensions.dart`
- Modify: All Brain v2 widgets (use extensions)

**Code Reduction**:
- Before: `final isDark = Theme.of(context).brightness == Brightness.dark;` (50+ chars × 20+ occurrences)
- After: `final isDark = context.isDarkMode;` (30 chars)
- Savings: ~400 characters of boilerplate

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] BuildContext extensions created
- [ ] AsyncValue extensions created
- [ ] All `Theme.of(context).brightness` replaced with `context.isDarkMode`
- [ ] AsyncValue.when patterns use build extension
- [ ] All widgets still render correctly
- [ ] No behavioral changes

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Verbose provider watching patterns
- **Source**: code-simplicity-reviewer agent (confidence: 65)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Dart Extensions**: https://dart.dev/guides/language/extension-methods
- **Riverpod Best Practices**: https://riverpod.dev/docs/concepts/reading
