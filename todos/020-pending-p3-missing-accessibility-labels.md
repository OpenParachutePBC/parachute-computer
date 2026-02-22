---
status: pending
priority: p3
issue_id: 100
tags: [code-review, accessibility, a11y]
dependencies: []
---

# Missing Accessibility: No Semantic Labels for Screen Readers

## Problem Statement

Interactive elements (buttons, cards, tabs) lack semantic labels and screen reader support. This makes the Brain v2 UI inaccessible to users with visual impairments.

**Impact**: Minor for current users, critical for accessibility. Violates accessibility guidelines (WCAG). Users relying on screen readers cannot navigate or use Brain v2.

## Findings

**Source**: pattern-recognition-specialist agent
**Confidence**: 70
**Examples**:

```dart
// brain_v2_entity_card.dart - No semantics
GestureDetector(
  onTap: widget.onTap,
  child: Card(...),  // ← Screen reader says "unlabeled button"
)

// brain_v2_home_screen.dart - FAB has no label
FloatingActionButton(
  onPressed: _handleCreateEntity,
  child: const Icon(Icons.add),  // ← Should have tooltip/semantics
)

// brain_v2_entity_list_screen.dart - Search has no hint
TextField(
  controller: _searchController,  // ← Missing semantics
)
```

**Missing Semantics**:
- Entity cards: No label describing entity
- Action buttons: No purpose description
- Form fields: No input instructions
- Tab navigation: Generic "tab N" instead of entity type names

## Proposed Solutions

### Option 1: Add Semantics widgets and labels (Recommended)
**Implementation**:

```dart
// Entity card with semantics
Semantics(
  label: '${entity.displayName}, ${widget.schema.name}',
  hint: 'Double tap to view details',
  button: true,
  child: GestureDetector(
    onTap: widget.onTap,
    child: Card(...),
  ),
)

// FAB with tooltip and semantics
Semantics(
  label: 'Create new ${_selectedSchema?.name ?? "entity"}',
  button: true,
  child: FloatingActionButton(
    onPressed: _handleCreateEntity,
    tooltip: 'Create new entity',  // ← Also shows on long press
    child: const Icon(Icons.add),
  ),
)

// Search field with semantics
TextField(
  controller: _searchController,
  decoration: InputDecoration(
    hintText: 'Search ${widget.entityType}...',
    semanticLabel: 'Search ${widget.entityType}',  // ← Screen reader label
    prefixIcon: const Icon(Icons.search, semanticLabel: 'Search icon'),
  ),
)

// Tab bar with labels
TabBar(
  tabs: schemas.map((schema) => Tab(
    text: schema.displayName,
    semanticLabel: 'View ${schema.displayName} entities',  // ← Clear purpose
  )).toList(),
)
```

**Pros**:
- Accessible to screen reader users
- WCAG compliant
- Better UX for all users
- Minimal code changes

**Cons**:
- Requires testing with screen readers

**Effort**: Medium (3-4 hours)
**Risk**: Very Low

### Option 2: Use ExcludeSemantics for decorative elements
**Implementation**: Hide purely decorative elements from screen readers

```dart
ExcludeSemantics(
  child: Icon(Icons.chevron_right),  // ← Decorative only
)
```

**Pros**:
- Reduces noise for screen readers
- Focuses on meaningful content

**Cons**:
- Requires careful judgment

**Effort**: Small (1-2 hours)
**Risk**: Very Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/widgets/brain_v2_entity_card.dart` (add semantics)
- `app/lib/features/brain_v2/screens/brain_v2_home_screen.dart` (FAB, tabs)
- `app/lib/features/brain_v2/screens/brain_v2_entity_list_screen.dart` (search)
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart` (form fields)
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart` (actions)

**Accessibility Checklist**:
- [ ] All interactive elements have semantic labels
- [ ] Buttons describe their action
- [ ] Form fields have input hints
- [ ] Navigation elements clearly state destination
- [ ] Decorative elements excluded from semantics tree
- [ ] Color contrast meets WCAG AA standards
- [ ] Focus indicators visible

**Testing**:
- iOS: VoiceOver
- Android: TalkBack
- Automated: Flutter's semantic tester

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All interactive elements have semantic labels
- [ ] Screen reader announces entity names on cards
- [ ] FAB announces purpose ("Create new entity")
- [ ] Search field has clear semantic label
- [ ] Tab navigation announces entity types
- [ ] Form fields announce labels and hints
- [ ] Manual test with VoiceOver/TalkBack: Complete create flow
- [ ] Flutter semantic debugger shows no issues

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Missing accessibility labels throughout UI
- **Source**: pattern-recognition-specialist agent (confidence: 70)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Flutter Accessibility**: https://docs.flutter.dev/development/accessibility-and-localization/accessibility
- **Semantics Widget**: https://api.flutter.dev/flutter/widgets/Semantics-class.html
- **WCAG Guidelines**: https://www.w3.org/WAI/WCAG21/quickref/
- **Testing**: https://docs.flutter.dev/testing/accessibility
