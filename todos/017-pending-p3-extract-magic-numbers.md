---
status: pending
priority: p3
issue_id: 100
tags: [code-review, code-quality, refactoring]
dependencies: []
---

# Extract Magic Numbers: Hardcoded Values Throughout UI

## Problem Statement

UI dimensions, durations, and thresholds are hardcoded as magic numbers throughout Brain v2 widgets. This makes the UI hard to maintain, inconsistent, and difficult to adjust for different screen sizes or accessibility needs.

**Impact**: Minor. Inconsistent spacing/sizing across screens. Hard to maintain visual consistency. No single source of truth for UI constants.

## Findings

**Source**: code-simplicity-reviewer agent
**Confidence**: 72
**Examples**:

```dart
// brain_v2_entity_list_screen.dart
padding: const EdgeInsets.all(16),  // ← Magic number
padding: const EdgeInsets.only(bottom: 80),  // ← Magic number

// brain_v2_form_builder.dart
padding: const EdgeInsets.only(bottom: 20),  // ← Magic number
fontSize: 14,  // ← Magic number
fontSize: 12,  // ← Magic number

// brain_v2_home_screen.dart
const Duration(milliseconds: 300),  // ← Magic number

// brain_v2_field_widget.dart
size: 18,  // Icon size
```

**Inconsistencies**:
- Padding values: 8, 10, 16, 20, 24, 32 (no consistent scale)
- Font sizes: 12, 13, 14, 16 (no typography system)
- Durations: 300ms (no named constants)

## Proposed Solutions

### Option 1: Extract to design token constants (Recommended)
**Implementation**:

```dart
// lib/core/theme/spacing.dart (add to existing design_tokens.dart)
class Spacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  // Semantic names
  static const double listPadding = md;
  static const double cardPadding = md;
  static const double formFieldGap = lg;
  static const double bottomNavSafeArea = 80;
}

class Typography {
  static const double bodyLarge = 16;
  static const double body = 14;
  static const double bodySmall = 12;
  static const double caption = 11;

  static const double iconSmall = 16;
  static const double iconMedium = 24;
  static const double iconLarge = 32;
}

class Durations {
  static const debounce = Duration(milliseconds: 300);
  static const shortAnimation = Duration(milliseconds: 200);
  static const mediumAnimation = Duration(milliseconds: 300);
  static const longAnimation = Duration(milliseconds: 500);
}

// Usage
padding: const EdgeInsets.all(Spacing.md),
fontSize: Typography.body,
Timer(Durations.debounce, () {...});
```

**Pros**:
- Single source of truth
- Easy to adjust globally
- Self-documenting
- Consistent UI

**Cons**:
- Refactoring effort across files

**Effort**: Medium (3-4 hours)
**Risk**: Very Low

### Option 2: Use theme extensions
**Implementation**: Add custom theme extensions

**Pros**:
- Theme-aware
- Can override per-theme

**Cons**:
- More complex
- Overkill for static values

**Effort**: Large (5+ hours)
**Risk**: Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/core/theme/design_tokens.dart` (add constants)
- All Brain v2 widget files (replace magic numbers)

**Magic Numbers to Extract**:
- Spacing/padding: 4, 6, 8, 10, 16, 20, 24, 32, 48, 80
- Font sizes: 11, 12, 13, 14, 16, 18
- Icon sizes: 16, 18, 24, 32, 48, 64
- Durations: 200ms, 300ms, 500ms

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All spacing values use Spacing constants
- [ ] All font sizes use Typography constants
- [ ] All durations use Durations constants
- [ ] No hardcoded numbers in padding, fontSize, or Duration
- [ ] Visual appearance unchanged
- [ ] Grep shows <5 instances of remaining magic numbers

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Magic numbers scattered throughout UI code
- **Source**: code-simplicity-reviewer agent (confidence: 72)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Design Tokens**: Already exists at `app/lib/core/theme/design_tokens.dart`
- **Best Practice**: https://m3.material.io/foundations/layout/understanding-layout/spacing
