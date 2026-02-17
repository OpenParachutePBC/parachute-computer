# Chat UI Fixups

**Date:** 2026-02-17
**Status:** Ready for planning
**Priority:** P2
**Modules:** app, chat

## What We're Building

A collection of targeted UI fixes addressing daily usability pain points in the chat interface, particularly on Android tablets with hardware keyboards.

## Problems

### 1. Hardware Keyboard IME Bar Covers Bottom Tabs
When a hardware keyboard is attached (e.g., Daylight tablet), Android shows a small IME suggestion bar at the bottom of the screen. This bar overlaps the bottom `NavigationBar` tabs rather than pushing them up. The app's `Scaffold` doesn't account for `viewInsets` or `viewPadding` changes from the IME bar when a hardware keyboard is present.

**Reproduction:** Attach hardware keyboard on Android tablet. The small bar appears at the bottom and covers the navigation tabs.

### 2. App Settings Access Requires Navigating to Daily
The only way to access app-wide settings is through the settings icon in the Daily tab. The settings icon in Chat is session-specific (context settings). Users expect a consistent way to reach app settings from any tab.

**Possible approaches:**
- Add a settings gear to the chat hub screen AppBar (alongside existing icons)
- Add a long-press or dedicated icon on the bottom navigation bar
- Add settings access to a user/profile area accessible from all tabs

### 3. Bottom Overflow by 8.0 Pixels on Chat Title
A persistent `RenderFlex overflowed by 8.0 pixels on the bottom` error appears at the top of the chat screen, likely in the title/toolbar area. This is a layout constraint issue in the app bar or embedded toolbar.

**Needs investigation:** Identify the exact widget causing the overflow — likely related to the title text or badge row in the embedded toolbar or standard app bar.

## Research Notes

### Relevant Patterns from Recent Work
- PR #59 fixed badge overflow in the embedded toolbar with `ConstrainedBox(maxWidth: 120)` per badge
- The 8px overflow may be a sibling issue in the title text or a different toolbar configuration
- Bottom sheet keyboard handling was improved with `MediaQuery.sizeOf()` — similar approach may help with the IME bar issue

### Flutter Keyboard/IME Handling
- `MediaQuery.viewInsets.bottom` reports the software keyboard height but may not account for the hardware keyboard IME bar
- `MediaQuery.viewPadding.bottom` may be the correct property to check for persistent bottom overlays
- The `Scaffold` `resizeToAvoidBottomInset` property controls whether the body resizes for the keyboard, but the `bottomNavigationBar` is handled separately

## Key Decisions

- These are independent bug fixes, not architectural changes
- Each can be addressed and tested separately
- The IME bar issue may require Android-specific investigation with the actual hardware

## Open Questions

- Is the 8px overflow reproducible on all devices or only certain screen sizes?
- Does the IME bar issue affect other Android devices or just the Daylight?
- Should we add a universal settings access point (all tabs) or just to the Chat tab?
