---
status: pending
priority: p1
issue_id: 100
tags: [code-review, flutter, memory-leak, lifecycle]
dependencies: []
---

# TabController Disposal Race: Listener Not Removed Before Disposal

## Problem Statement

In `brain_v2_home_screen.dart`, the TabController is disposed without removing its listener first, and a new listener is added to a potentially already-disposed controller. This creates a race condition where listeners can fire after disposal, causing crashes or memory leaks.

**Impact**: Crashes when schemas reload (causing tab count changes) and listeners fire on disposed controllers. Memory leaks from orphaned listeners that never get cleaned up.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 92
**Location**: `app/lib/features/brain_v2/screens/brain_v2_home_screen.dart:129-132`

**Evidence**:
```dart
// Lines 129-132 - UNSAFE disposal pattern
if (_tabController == null || _tabController!.length != schemas.length) {
  _tabController?.dispose();  // ← Listener still attached!
  _tabController = TabController(length: schemas.length, vsync: this);
  _tabController!.addListener(() {  // ← New listener added
    setState(() {
      _selectedIndex = _tabController!.index;
    });
  });
}
```

**Problem Flow**:
1. Listener added to TabController
2. Schema list changes (different length)
3. `dispose()` called with listener still attached
4. If listener callback was pending, it fires on disposed controller → crash
5. New controller created, new listener added
6. Old listener never removed → memory leak

## Proposed Solutions

### Option 1: Remove listener before disposal (Recommended)
**Implementation**:
```dart
// Add listener callback as instance field
void _onTabChanged() {
  if (mounted) {
    setState(() {
      _selectedIndex = _tabController?.index ?? 0;
    });
  }
}

// In build or initState
if (_tabController == null || _tabController!.length != schemas.length) {
  _tabController?.removeListener(_onTabChanged);  // ← Remove first
  _tabController?.dispose();
  _tabController = TabController(length: schemas.length, vsync: this);
  _tabController!.addListener(_onTabChanged);
}

// In dispose()
@override
void dispose() {
  _tabController?.removeListener(_onTabChanged);
  _tabController?.dispose();
  super.dispose();
}
```

**Pros**:
- Proper lifecycle management
- No race conditions
- Standard Flutter pattern
- Listeners properly cleaned up

**Cons**:
- Requires extracting callback to named method (good practice anyway)

**Effort**: Small (15 minutes)
**Risk**: Very Low

### Option 2: Create new controller every time
**Implementation**: Always dispose and recreate, no reuse

```dart
_tabController?.removeListener(_onTabChanged);
_tabController?.dispose();
_tabController = TabController(length: schemas.length, vsync: this);
_tabController!.addListener(_onTabChanged);
```

**Pros**:
- Simpler logic
- No conditional reuse

**Cons**:
- Slightly less efficient (recreates even if length unchanged)
- Still need to remove listener before disposal

**Effort**: Small (15 minutes)
**Risk**: Very Low

### Option 3: Use DefaultTabController
**Implementation**: Let Flutter manage lifecycle

**Pros**:
- No manual lifecycle management
- Framework handles everything

**Cons**:
- Requires widget tree restructure
- Loses explicit index control
- More invasive change

**Effort**: Large (1+ hour)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/screens/brain_v2_home_screen.dart` (lines 129-132, dispose method)

**Affected Components**:
- BrainV2HomeScreen tab navigation
- Schema-driven tab bar
- Tab switching behavior

**Current Lifecycle Issues**:
1. Listener not removed before disposal (line 130)
2. No listener removal in dispose() method
3. Anonymous listener function (can't be removed)

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] Listener callback extracted to named instance method
- [ ] Listener removed before TabController disposal (line ~130)
- [ ] Listener removed in dispose() method
- [ ] No crashes when schema list changes length
- [ ] No memory leaks from orphaned listeners
- [ ] Tab switching still works correctly
- [ ] DevTools Memory profiler shows no retained listeners after disposal

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: TabController disposed without removing listener first
- **Source**: flutter-reviewer agent (confidence: 92)
- **Risk**: Can cause crashes when schema count changes

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Flutter Docs**: https://api.flutter.dev/flutter/widgets/TickerProviderStateMixin-mixin.html
- **TabController Docs**: https://api.flutter.dev/flutter/material/TabController-class.html
- **Best Practice**: Always remove listeners before disposing controllers
- **Location**: `brain_v2_home_screen.dart:129-132`
