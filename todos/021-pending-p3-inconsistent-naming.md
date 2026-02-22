---
status: pending
priority: p3
issue_id: 100
tags: [code-review, code-quality, naming]
dependencies: []
---

# Inconsistent Naming: Mixed Conventions and Abbreviations

## Problem Statement

Variable and method names use inconsistent conventions. Some use abbreviations (isDark, msg), others spell out fully. Some use Entity, others use item/element. This makes code slightly harder to read.

**Impact**: Minor. Slightly reduces code readability. No functional issues. Opportunity for consistency.

## Findings

**Source**: code-simplicity-reviewer agent
**Confidence**: 60
**Examples**:

```dart
// Inconsistent abbreviations
final msg = controller.text;  // ← Abbreviated
final message = _getMessage();  // ← Full spelling (elsewhere)

final commitMsg = ...;  // ← Abbreviated
final commitMessage = ...;  // ← Full spelling (elsewhere)

// Inconsistent terminology
final entity = ...;  // ← Most common
final item = ...;  // ← Used in some loops
final element = ...;  // ← Used occasionally

// Boolean naming
final isDark = ...;  // ← Good (is prefix)
final dark = ...;  // ← Missing 'is' prefix (elsewhere)
```

**Patterns**:
- Message sometimes "msg", sometimes "message"
- Booleans sometimes have "is" prefix, sometimes don't
- Loop variables use entity/item/element interchangeably

## Proposed Solutions

### Option 1: Standardize naming conventions (Recommended)
**Implementation**:

**Convention Rules**:
```dart
// Booleans: Always use 'is', 'has', 'should' prefix
final isDark = ...;  // ✓
final isLoading = ...;  // ✓
final hasError = ...;  // ✓

// Abbreviations: Only standard ones (id, url, api)
final commitMessage = ...;  // ✓ (spell out message)
final entityId = ...;  // ✓ (id is standard)
final apiUrl = ...;  // ✓ (api, url are standard)

// Domain objects: Use full term consistently
final entity = entities[index];  // ✓ (use 'entity')
final schema = schemas[i];  // ✓ (use 'schema')

// Callbacks: Use 'handle' or 'on' prefix
void _handleSubmit() { }  // ✓
void _onChanged(value) { }  // ✓
```

**Renaming Checklist**:
- [ ] `msg` → `message` (3 occurrences)
- [ ] `commitMsg` → `commitMessage` (5 occurrences)
- [ ] Add `is` prefix to boolean variables missing it
- [ ] Standardize loop variables to use domain term (entity, schema)

**Pros**:
- Consistent codebase
- Easier to read
- Professional code quality

**Cons**:
- Refactoring time
- Git history noise

**Effort**: Small (2-3 hours)
**Risk**: Very Low

### Option 2: Document conventions only
**Implementation**: Add CONTRIBUTING.md with naming conventions

**Pros**:
- No code changes
- Guides future work

**Cons**:
- Doesn't fix existing issues
- Inconsistency remains

**Effort**: Small (1 hour)
**Risk**: Very Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_entity_form_screen.dart` (msg → message)
- `app/lib/features/brain_v2/screens/brain_v2_entity_detail_screen.dart` (msg → message)
- Various files with inconsistent loop variable names

**Naming Conventions to Apply**:

| Type | Convention | Example |
|------|------------|---------|
| Booleans | is/has/should prefix | `isDark`, `hasError` |
| Private methods | _ prefix, action verb | `_handleSubmit`, `_buildCard` |
| Callbacks | handle/on prefix | `_handleTap`, `_onChanged` |
| Abbreviations | Only standard | `id`, `url`, `api` (not `msg`) |
| Domain objects | Full term | `entity`, `schema`, `field` |

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All `msg` renamed to `message`
- [ ] All booleans have appropriate prefix
- [ ] Loop variables use domain terms consistently
- [ ] No functional changes
- [ ] All references updated
- [ ] Code compiles and tests pass

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Inconsistent variable naming throughout codebase
- **Source**: code-simplicity-reviewer agent (confidence: 60)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Dart Style Guide**: https://dart.dev/guides/language/effective-dart/style
- **Naming Conventions**: https://dart.dev/guides/language/effective-dart/usage
