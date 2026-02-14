# Parachute App Test Plan

> Living test plan for agentic and automated testing of the Parachute Flutter app.

---

## Layer 1: Flutter Integration Tests

Run these with `flutter test integration_test/<file>.dart`. Each launches the macOS app in a test harness.

### app_test.dart (9 tests)
- [ ] App renders with correct theme (MaterialApp present)
- [ ] Design tokens are valid (BrandColors.forest, nightForest, turquoise, nightTurquoise)
- [ ] Full mode shows 4 navigation destinations
- [ ] All tab labels present (Chat, Daily, Vault, Brain)
- [ ] Tapping tabs does not crash
- [ ] Tab icons are correct
- [ ] Daily-only mode has no navigation bar
- [ ] No NavigationDestinations in daily-only mode
- [ ] App renders in dark mode without crash

### brain_test.dart (7 tests)
- [ ] BrainEntity parses from JSON
- [ ] BrainSearchResult parses from JSON
- [ ] BrainTagChip renders tag text
- [ ] BrainEntityCard renders name, tags, snippet
- [ ] BrainScreen shows search field and empty state
- [ ] Search field accepts input (debounce fires, clear button appears)
- [ ] BrainEntityScreen shows entity name in app bar

### chat_test.dart (2 tests)
- [ ] ChatSession model parses correctly (title, displayTitle, source, nullable title)
- [ ] StreamEventType has all expected values (14 types)

### daily_test.dart (2 tests)
- [ ] JournalEntry model works correctly
- [ ] JournalEntryType enum has expected values (text, voice)

### settings_test.dart (3 tests)
- [ ] BotConnectorsSection renders header
- [ ] HooksSection renders header
- [ ] New settings sections are ConsumerStatefulWidgets

---

## Layer 2: Agentic Testing (Marionette MCP)

These tests are performed by Claude walking through the running app using Marionette MCP tools. Run the app in debug mode first, note the VM service URI, then use `/test-app` to start the walkthrough.

### Prerequisites
1. Server running on `localhost:3336` with valid vault
2. App launched in debug mode: `flutter run -d macos`
3. VM service URI visible in console (e.g., `ws://127.0.0.1:XXXXX/ws`)

### Test Flows

#### Flow 1: App Launch and Navigation
1. Connect to running app via Marionette
2. Take screenshot of initial state
3. Verify 4 tabs visible: Chat, Daily, Vault, Brain
4. Tap each tab sequentially, screenshot after each
5. Verify each tab's content loads without error

#### Flow 2: Brain Search
1. Navigate to Brain tab
2. Verify empty state message visible ("Search your Brain")
3. Tap search field, enter "parachute"
4. Wait for debounce (300ms) + results
5. Screenshot results (or "No results" if no server)
6. Clear search, verify empty state returns

#### Flow 3: Chat Tab
1. Navigate to Chat tab
2. Verify chat hub loads (session list or empty state)
3. If sessions exist, tap one and verify chat screen loads
4. Verify message input field is present

#### Flow 4: Daily Tab
1. Navigate to Daily tab
2. Verify journal view loads
3. Check for date display and entry list
4. Verify recorder area is present

#### Flow 5: Vault Tab
1. Navigate to Vault tab
2. Verify file browser loads
3. Check for folder structure display

#### Flow 6: Settings
1. Open settings (via gear icon or navigation)
2. Scroll through settings sections
3. Verify "Bot Connectors" section visible
4. Verify "Hooks" section visible
5. Screenshot settings page

#### Flow 7: Dark Mode
1. Toggle dark mode (if accessible via settings)
2. Screenshot each tab in dark mode
3. Verify no rendering issues (text visible, icons contrast OK)

---

## Running Tests

### All integration tests (sequential — don't run in parallel)
```bash
cd repos/parachute-app
flutter test integration_test/app_test.dart
flutter test integration_test/brain_test.dart
flutter test integration_test/chat_test.dart
flutter test integration_test/daily_test.dart
flutter test integration_test/settings_test.dart
```

### Agentic test via Claude Code
```
/test-app
```

---

## Test Results Log

| Date | Integration (23 total) | Agentic | Notes |
|------|----------------------|---------|-------|
| 2026-02-05 | 23/23 pass | N/A | Initial test suite created |
| 2026-02-05 | 23/23 pass | Skipped (no running app) | /test-app skill run — all green |
