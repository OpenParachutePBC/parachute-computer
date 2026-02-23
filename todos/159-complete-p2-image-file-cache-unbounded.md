---
status: complete
priority: p2
issue_id: 109
tags: [code-review, flutter, performance, chat]
dependencies: []
---

# `_imageFileCache` is unbounded and caches null values permanently

## Problem Statement

`_imageFileCache` in `_MessageBubbleState` is a `static final Map<String, File?>` with no size limit and no eviction. It also caches `null` for files that don't exist at lookup time — if an image file is created later (e.g., agent produces the file after the bubble is first rendered), the cached `null` prevents it from ever loading. The similar `_styleSheetCache` in the same file correctly implements a bounded cache (`_maxStyleSheetCacheSize = 50`). This is pre-existing code but flagged here as it warrants attention for long-running sessions.

## Findings

- **Source**: performance-oracle (P2, confidence: 83)
- **Location**: `app/lib/features/chat/widgets/message_bubble.dart:575`
- **Evidence**:
  ```dart
  static final Map<String, File?> _imageFileCache = {};
  // No eviction, no size cap, caches null results
  ```
  Compare `_styleSheetCache` at line ~800: `if (_styleSheetCache.length >= _maxStyleSheetCacheSize) { _styleSheetCache.clear(); }`

## Proposed Solutions

### Solution A: Cap size and stop caching nulls (Recommended)
```dart
static final Map<String, File> _imageFileCache = {};
static const int _maxImageCacheSize = 200;

// In _findImageFile():
if (_imageFileCache.containsKey(path)) {
  return _imageFileCache[path];
}
// ... existing lookup ...
if (found != null) {
  if (_imageFileCache.length >= _maxImageCacheSize) {
    _imageFileCache.clear();
  }
  _imageFileCache[path] = found;
  return found;
}
return null; // Do not cache null — file may appear later
```
- **Pros**: Bounds memory; fixes stale-null bug; mirrors existing `_styleSheetCache` pattern
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `app/lib/features/chat/widgets/message_bubble.dart`

## Acceptance Criteria

- [ ] `_imageFileCache.length` never exceeds 200
- [ ] Null results are not cached (file can load if created after initial lookup)
- [ ] Pattern matches `_styleSheetCache` bounded eviction implementation

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #109: feat(chat): Tap-to-expand streaming, inline AskUserQuestion, fix expired status
- `_styleSheetCache` reference: `message_bubble.dart` `_maxStyleSheetCacheSize`
