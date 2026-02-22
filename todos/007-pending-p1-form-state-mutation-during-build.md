---
status: pending
priority: p1
issue_id: 100
tags: [code-review, flutter, state-management, build-safety]
dependencies: []
---

# Form State Mutation During Build: setState in Listener Callback

## Problem Statement

In `brain_v2_form_builder.dart`, the `_updateFormData()` method calls `setState()` inside a TextEditingController listener callback. This listener fires during text input, which can occur during the build phase, causing "setState during build" errors and unpredictable widget behavior.

**Impact**: Random crashes with "setState() or markNeedsBuild() called during build" errors. Form input can become laggy or unresponsive. Parent widget callback (`onDataChanged`) fires during setState, violating single-responsibility of state updates.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 93
**Location**: `app/lib/features/brain_v2/widgets/brain_v2_form_builder.dart:60-82`

**Evidence**:
```dart
// Lines 60-82 - UNSAFE setState in listener
void _updateFormData() {
  setState(() {  // ← Can fire during build!
    for (final field in widget.schema.fields) {
      if (_controllers.containsKey(field.name)) {
        final text = _controllers[field.name]!.text;

        if (field.type == 'integer') {
          _formData[field.name] = text.isEmpty ? null : int.tryParse(text);
        } else if (field.type == 'array' && field.itemsType == 'string') {
          _formData[field.name] = text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        } else {
          _formData[field.name] = text.isEmpty ? null : text;
        }
      }
    }

    widget.onDataChanged(_formData);  // ← Parent callback during setState!
  });
}

// Lines 42 - Listener added in initState
controller.addListener(() => _updateFormData());  // ← Fires on every keystroke
```

**Problem Flow**:
1. User types in TextField
2. TextEditingController notifies listeners
3. Listener calls `_updateFormData()`
4. `setState()` called, triggers rebuild
5. If parent is also building, "setState during build" exception
6. `widget.onDataChanged()` called during setState → anti-pattern

## Proposed Solutions

### Option 1: Post-frame callback for state updates (Recommended)
**Implementation**:
```dart
void _updateFormData() {
  // Schedule setState for after current frame
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      setState(() {
        // Move all mutation logic here
        for (final field in widget.schema.fields) {
          if (_controllers.containsKey(field.name)) {
            final text = _controllers[field.name]!.text;

            if (field.type == 'integer') {
              _formData[field.name] = text.isEmpty ? null : int.tryParse(text);
            } else if (field.type == 'array' && field.itemsType == 'string') {
              _formData[field.name] = text
                  .split(',')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
            } else {
              _formData[field.name] = text.isEmpty ? null : text;
            }
          }
        }
      });

      // Call parent callback AFTER setState completes
      widget.onDataChanged(_formData);
    }
  });
}
```

**Pros**:
- Guarantees setState happens outside build phase
- Maintains reactive form updates
- Standard Flutter pattern
- No behavior changes for users

**Cons**:
- Slight delay (1 frame) in state propagation

**Effort**: Small (15 minutes)
**Risk**: Very Low

### Option 2: Separate setState from data update
**Implementation**:
```dart
void _updateFormData() {
  // Update data WITHOUT setState
  for (final field in widget.schema.fields) {
    if (_controllers.containsKey(field.name)) {
      final text = _controllers[field.name]!.text;
      _formData[field.name] = _parseFieldValue(field, text);
    }
  }

  // Notify parent (no setState needed - parent decides if rebuild)
  widget.onDataChanged(_formData);

  // Only setState if we need to rebuild (we don't for text input)
  // setState(() {});  // ← Remove unless needed for UI changes
}
```

**Pros**:
- Eliminates unnecessary rebuilds
- Faster - no widget tree rebuild on every keystroke
- Clear separation of data update vs UI update

**Cons**:
- May miss edge cases where rebuild is actually needed

**Effort**: Small (20 minutes)
**Risk**: Low

### Option 3: Debounce updates
**Implementation**: Use Timer to batch rapid updates

**Pros**:
- Reduces update frequency
- Better performance

**Cons**:
- Adds complexity
- Doesn't solve root problem (setState during build)
- Still need Option 1 or 2

**Effort**: Medium (30 minutes)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/widgets/brain_v2_form_builder.dart` (lines 60-82, line 42)

**Affected Components**:
- BrainV2FormBuilder (all form inputs)
- BrainV2EntityFormScreen (uses form builder)
- Create/Edit entity flows

**setState During Build Error**:
```
setState() or markNeedsBuild() called during build.
This Overlay widget cannot be marked as needing to build because the framework
is already in the process of building widgets.
```

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] No setState calls in TextEditingController listeners during build phase
- [ ] Form data updates correctly on text input
- [ ] Parent callback (`onDataChanged`) fires after state updates complete
- [ ] No "setState during build" errors in console
- [ ] Form input remains responsive
- [ ] Manual test: Type rapidly in multiple fields → no crashes
- [ ] Flutter DevTools shows no build-phase setState warnings

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: setState called in listener callback that fires during build
- **Source**: flutter-reviewer agent (confidence: 93)
- **Pattern**: Common Flutter anti-pattern causing intermittent crashes

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Flutter Docs**: https://api.flutter.dev/flutter/widgets/State/setState.html
- **Post-Frame Callbacks**: https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addPostFrameCallback.html
- **Best Practice**: Never call setState from listeners that can fire during build
- **Location**: `brain_v2_form_builder.dart:60-82`
