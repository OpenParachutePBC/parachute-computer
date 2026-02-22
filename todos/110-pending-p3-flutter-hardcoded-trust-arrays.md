---
status: pending
priority: p3
issue_id: 62
tags: [code-review, flutter, quality, dry-principle]
created: 2026-02-21
---

# Hardcoded Trust Level Arrays Instead of Deriving from Enum

## Problem Statement

Multiple Flutter widget files define hardcoded string arrays `['direct', 'sandboxed']` instead of deriving them from the `TrustLevel` enum. This violates the DRY principle and creates maintenance burden if a third trust level is added.

**Impact:** Low-medium - Future changes to trust levels require updating 3+ hardcoded arrays instead of just the enum.

**Introduced in:** Commit 8f93d13 (trust level rename updated these arrays but didn't eliminate them)

## Findings

**Source:** Flutter Reviewer (Confidence: 92)

**Locations:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/settings/widgets/bot_connectors_section.dart:50`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/chat/widgets/session_config_sheet.dart:49`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/chat/widgets/unified_session_settings.dart:341`

**Current pattern:**
```dart
static const _trustLevels = ['direct', 'sandboxed'];
```

**Why this is a problem:**
1. **Single source of truth violation** - The `TrustLevel` enum already defines these values, but widgets duplicate them
2. **Maintenance burden** - If a third trust level is added, developers must remember to update all hardcoded arrays
3. **Not Dart 3 idiomatic** - Modern Dart favors deriving from enums using `EnumName.values`

**Risk scenario:**
If a future commit adds `TrustLevel.restricted`, the enum would have 3 values but dropdowns would still show only 2 options until someone notices and manually updates each array.

## Proposed Solutions

### Solution 1: Derive from Enum (Recommended)

**Approach:** Use `TrustLevel.values` to generate the string list dynamically.

**Implementation:**
```dart
// Instead of:
static const _trustLevels = ['direct', 'sandboxed'];

// Use:
static final _trustLevels = TrustLevel.values.map((e) => e.name).toList();
```

**Note:** Must be `final` not `const` because `.map()` is not a const expression. This is acceptable - the list is still computed once at initialization.

**Pros:**
- Single source of truth (enum)
- Automatic updates when enum changes
- Dart 3 best practice
- Only 1 line of code

**Cons:**
- `final` instead of `const` (minimal impact - still immutable)

**Effort:** Minimal (5 minutes - update 3 files)
**Risk:** Very low

### Solution 2: Extract to Shared Constant

**Approach:** Define a top-level constant in `trust_level.dart` and import it.

**Implementation:**
```dart
// trust_level.dart
const kTrustLevelNames = ['direct', 'sandboxed'];

// widgets
import 'package:parachute/features/settings/models/trust_level.dart';
static const _trustLevels = kTrustLevelNames;
```

**Pros:**
- Single location to update
- Remains `const`

**Cons:**
- Still hardcoded (enum is not source of truth)
- Requires importing from a different package

**Effort:** Small (10 minutes)
**Risk:** Low

### Solution 3: Keep Separate (Not Recommended)

**Approach:** Accept duplication as intentional.

**Pros:**
- No code changes

**Cons:**
- Continues to violate DRY
- Future maintenance burden

**Effort:** None
**Risk:** Technical debt accumulation

## Recommended Action

Implement **Solution 1** - derive from `TrustLevel.values`. This is the idiomatic Dart 3 approach and automatically keeps widgets in sync with the enum.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/settings/widgets/bot_connectors_section.dart:50`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/chat/widgets/session_config_sheet.dart:49`
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/app/lib/features/chat/widgets/unified_session_settings.dart:341`

**Components:**
- Trust level dropdowns in settings
- Session configuration UI
- Bot connector configuration

**Database changes:** None

## Acceptance Criteria

- [ ] Replace `static const _trustLevels = ['direct', 'sandboxed']` with derived list in all 3 files
- [ ] Use `TrustLevel.values.map((e) => e.name).toList()`
- [ ] Verify dropdowns still show correct options
- [ ] All existing Flutter tests pass
- [ ] UI renders correctly (no visual regression)

## Work Log

- **2026-02-21**: Issue identified during Flutter code review of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename (updated arrays but didn't eliminate duplication)

**Dart enum best practices:**
- https://dart.dev/language/enums#declaring-enhanced-enums
- Prefer deriving from enums over hardcoded copies
