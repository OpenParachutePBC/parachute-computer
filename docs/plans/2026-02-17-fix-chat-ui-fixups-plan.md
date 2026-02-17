---
title: "fix: Chat UI fixups — IME bar, settings access, title overflow"
type: fix
date: 2026-02-17
issue: "#60"
deepened: 2026-02-17
---

# fix: Chat UI fixups — IME bar, settings access, title overflow

## Enhancement Summary

**Deepened on:** 2026-02-17
**Agents used:** flutter-reviewer, best-practices-researcher, code-simplicity-reviewer, spec-flow-analyzer

### Key Corrections from Research
1. **Fix 1**: SafeArea wrap is WRONG — NavigationBar already has SafeArea internally (double-padding risk). SafeArea handles `viewPadding`, not `viewInsets`. Use `Padding` with `MediaQuery.viewInsetsOf(context).bottom` instead.
2. **Fix 2**: `Navigator.push(context)` is WRONG — pushes inside tab navigator, keeping bottom bar visible. Must use `Navigator.of(context, rootNavigator: true).push(...)`.
3. **Fix 3**: `toolbarHeight: 64` is fragile — duplicates `hasBadges` logic, introduces magic number, causes layout jump. Use `SizedBox(height: 16)` wrapper on badge row instead.

---

## Overview

Three independent UI bug fixes addressing daily usability pain points: (1) hardware keyboard IME bar overlapping bottom navigation tabs, (2) inconsistent settings access across tabs, (3) 8px bottom overflow on the chat AppBar title when badges are shown.

## Problem Statement

1. **IME bar covers tabs**: On Android tablets with hardware keyboards (e.g., Daylight), the OS shows a small IME suggestion bar at the bottom of the screen that overlaps the `NavigationBar` tabs because no `viewInsets` handling protects the bottom navigation.

2. **Settings access inconsistent**: App-wide settings are accessible from ChatHub, Daily, and Vault AppBars, but **missing** from BrainScreen and the tablet/desktop SessionListPanel sidebar. Users must navigate to another tab to reach settings.

3. **Title overflow**: `_buildTitle()` in `chat_screen.dart` stacks a title `Row` + badges `SingleChildScrollView` in a `Column`, which exceeds the default 56px `AppBar` toolbarHeight when badges are present, causing an 8px bottom overflow.

## Fix 1: Hardware Keyboard IME Bar Covering Bottom Tabs

### Root Cause

`app/lib/main.dart:610-681` — The `_TabShell` Scaffold places a `NavigationBar` as `bottomNavigationBar` with no bottom inset handling. When a hardware keyboard's IME suggestion bar appears, it occupies space that the `NavigationBar` doesn't account for.

### Research Insights

- **NavigationBar already has SafeArea internally** (confirmed via Flutter source: `navigation_bar.dart` wraps content in `SafeArea`). Wrapping in another SafeArea causes double-padding on devices with home indicators. [Flutter issue #135030]
- **SafeArea handles `viewPadding`, NOT `viewInsets`**. The IME suggestion bar from hardware keyboards is reported through `viewInsets.bottom`, not `viewPadding.bottom`.
- **`Scaffold.resizeToAvoidBottomInset`** (default true) resizes the body for `viewInsets`, but the `bottomNavigationBar` slot sits below the resized body and is NOT pushed up by keyboard insets.
- **`maintainBottomViewPadding: true`** on NavigationBar prevents jitter when IME bar appears/disappears in edge-to-edge mode.

### Proposed Fix

Use `Padding` with `MediaQuery.viewInsetsOf(context).bottom` to push the NavigationBar above the IME bar:

```dart
// app/lib/main.dart ~line 665
bottomNavigationBar: showNavBar
    ? Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: (index) { ... },
          backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          indicatorColor: ...,
          destinations: destinations,
        ),
      )
    : null,
```

### Acceptance Criteria

- [ ] `NavigationBar` wrapped in `Padding` with `MediaQuery.viewInsetsOf(context).bottom` in `app/lib/main.dart`
- [ ] Bottom tabs remain fully visible when hardware keyboard IME bar is shown on Android
- [ ] No double-padding on devices with home indicators (iPhone, gesture-nav Android)
- [ ] No visual regression on iOS, macOS, or web (viewInsets.bottom is 0 when no IME bar)

### Edge Cases

- **Soft keyboard open (no hardware keyboard)**: `viewInsets.bottom` reports the full keyboard height. However, `Scaffold.resizeToAvoidBottomInset` (default true) already handles this by shrinking the body. The bottom nav bar with additional padding may be pushed further down or off-screen. If this is an issue, gate the padding: only apply when `viewInsets.bottom > 0 && viewInsets.bottom < 100` (IME bar is typically 48-56dp, not the full 250+ dp keyboard).
- **Keyboard disconnect/reconnect**: `MediaQuery` triggers rebuilds automatically.
- **Desktop/web**: `viewInsets.bottom` is 0. No visual change.

---

## Fix 2: Settings Access from Any Tab

### Root Cause

Settings icon is present in:
- `ChatHubScreen` AppBar (`chat_hub_screen.dart:118-132`)
- `AgentHubScreen` AppBar (`agent_hub_screen.dart:104-114`)
- Daily `JournalHeader` (`journal_header.dart:109-123`)
- Vault `FilesScreen` and `RemoteFilesScreen` AppBars
- `ChatScreen` connection error banner (as "Settings" button)

Settings icon is **missing** from:
- `BrainScreen` (`brain_screen.dart:80-89`) — AppBar only has a refresh button
- `SessionListPanel` tablet/desktop sidebar (`session_list_panel.dart`) — header has new chat, search, archive buttons but no settings

### Research Insights

- **Navigator architecture**: Each tab has its own `Navigator` with a `GlobalKey`. `Navigator.push(context)` from inside a tab pushes within that tab's navigator — the bottom bar stays visible.
- **Must use `rootNavigator: true`**: `Navigator.of(context, rootNavigator: true).push(...)` pushes above the tab shell, hiding the bottom bar. This is the correct pattern for full-screen settings.
- **Existing code is inconsistent**: `chat_hub_screen.dart:125` and `journal_header.dart:116` use `Navigator.push(context)` (tab-level). `main.dart:343` uses `pushNamed('/settings')` (root-level via deep link). The named route `/settings` is registered on root `MaterialApp` (line 184), so `pushNamed` from a tab context may work by accident but is fragile.
- **Simplicity note**: SessionListPanel users on tablet already have settings access via the adjacent ChatScreen or ChatHubScreen. Adding to BrainScreen only covers the actual gap. However, for completeness and discoverability on tablet, add to both.

### Proposed Fix

Add settings icons to both screens, using `rootNavigator: true`:

**BrainScreen** (`app/lib/features/brain/screens/brain_screen.dart`):
```dart
appBar: AppBar(
  title: const Text('Brain'),
  actions: [
    IconButton(
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    ),
    IconButton(
      icon: const Icon(Icons.refresh),
      onPressed: _loadBrainStatus,
    ),
  ],
),
```

**SessionListPanel** (`app/lib/features/chat/widgets/session_list_panel.dart`):
```dart
// In the header actions row, add before the existing search button:
IconButton(
  icon: Icon(
    Icons.settings_outlined,
    size: 20,
    color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
  ),
  onPressed: () => Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => const SettingsScreen()),
  ),
  tooltip: 'Settings',
),
```

### Acceptance Criteria

- [ ] Settings icon added to `BrainScreen` AppBar using `rootNavigator: true`
- [ ] Settings icon added to `SessionListPanel` header using `rootNavigator: true`
- [ ] Settings opens full-screen (above tab bar) from both new locations
- [ ] All existing settings access points still work (no regressions)
- [ ] Icon style matches existing settings icons (`Icons.settings_outlined`)

### Edge Cases

- **Tablet layout**: Settings pushed with `rootNavigator: true` covers the entire screen including tab bar. This is the correct UX for app-wide settings.
- **Back navigation**: Standard back button/gesture pops from root navigator, returning to the tab shell.

---

## Fix 3: 8px Bottom Overflow on Chat Title

### Root Cause

`app/lib/features/chat/screens/chat_screen.dart:764-848` — `_buildTitle()` builds a `Column(mainAxisSize: MainAxisSize.min)` containing:
1. A `Row` with icon (20px) + title text (16px font, ~24px with line height) + dropdown arrow (20px)
2. Conditionally, a `SingleChildScrollView` with a `Row` of badges (10px font, ~14px tall with padding)

When badges are shown, the Column's natural height (~38px+) exceeds the AppBar's default `toolbarHeight` of 56px after accounting for AppBar internal padding (~16px total), causing the 8px overflow.

The **embedded toolbar** (`_buildEmbeddedToolbar()`, line 475) doesn't have this problem because it puts title + badges in a single `Row` with `Flexible(flex: 0)` on badges.

### Research Insights

- **`toolbarHeight: 64` is fragile** — duplicates `hasBadges` logic outside `_buildTitle()`, introduces a magic number (64), and causes visible layout jump when badges appear/disappear during streaming.
- **Simpler fix: constrain badge row height** — Wrap the `SingleChildScrollView` in `SizedBox(height: 16)` inside `_buildTitle()`. This keeps all layout logic in one place, doesn't change AppBar height, and avoids layout jumps. [Code simplicity reviewer]
- **Duplicate badge rendering in embedded mode** — `_buildTitle()` renders badges unconditionally, but `_buildEmbeddedToolbar()` also renders its own badges (lines 500-601). In embedded mode, badges appear twice. This is a pre-existing bug but should be noted. [Spec flow analyzer]

### Proposed Fix

Constrain the badge row height inside `_buildTitle()`:

```dart
// Inside _buildTitle(), wrap the badge SingleChildScrollView:
if (hasBadges)
  SizedBox(
    height: 16,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [ /* existing badge widgets */ ],
      ),
    ),
  ),
```

This is:
- **1 widget added** (SizedBox wrapper) vs ~5 lines for hasBadges duplication + toolbarHeight conditional
- **Self-contained** in `_buildTitle()` — no leaking layout concerns
- **No runtime AppBar height changes** — avoids animation jank

### Acceptance Criteria

- [ ] Badge row wrapped in `SizedBox(height: 16)` in `_buildTitle()` in `chat_screen.dart`
- [ ] No `RenderFlex overflowed` error when badges are shown
- [ ] Title + badges render cleanly without clipping or overflow
- [ ] AppBar height remains default 56px in all cases
- [ ] Visual consistency — badges still readable at constrained height

### Edge Cases

- **No badges**: SizedBox not rendered. No visual change.
- **Long title + many badges**: Title has `maxLines: 1` + `TextOverflow.ellipsis`. Badges have `maxWidth: 120` constraints. Both handled.
- **Embedded mode (tablet/desktop)**: Uses `_buildEmbeddedToolbar()` which has its own layout. This fix only affects the standard `AppBar` on mobile/narrow layouts. Note: duplicate badge rendering in embedded mode is a pre-existing issue (out of scope for this fix).

---

## Implementation Order

These fixes are independent. Suggested order:

1. **Fix 3** (title overflow) — smallest change, immediate visual improvement
2. **Fix 2** (settings access) — two files, straightforward icon additions with rootNavigator
3. **Fix 1** (IME bar) — Padding with viewInsetsOf, needs Android testing

## References

- Brainstorm: `docs/brainstorms/2026-02-17-chat-ui-fixups-brainstorm.md`
- Issue: #60
- Related PR: #59 (badge overflow fixes in embedded toolbar)
- App CLAUDE.md layout conventions: `app/CLAUDE.md:122-165`
- Flutter NavigationBar source: internal SafeArea wrapping confirmed
- Flutter issue #135030: NavigationBar redundant bottom padding
- Flutter issue #30547: Allow multiline text in AppBar
