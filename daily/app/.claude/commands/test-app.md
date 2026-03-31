# Test Parachute App

Run the full test suite for the Parachute Flutter app. This includes both automated integration tests and (optionally) agentic walkthrough testing via Marionette MCP.

## Step 1: Run Integration Tests

Run each integration test file sequentially (they share the macOS app process and cannot run in parallel):

```bash
cd repos/parachute-app
flutter test integration_test/app_test.dart
flutter test integration_test/brain_test.dart
flutter test integration_test/chat_test.dart
flutter test integration_test/daily_test.dart
flutter test integration_test/settings_test.dart
```

Report the results as a table:

| Test file | Pass/Fail | Details |
|-----------|-----------|---------|

## Step 2: Agentic Testing (if Marionette MCP available)

If the Marionette MCP server is connected and the app is running in debug mode:

1. **Connect** to the running app using the VM service URI from the console
2. **Take a screenshot** of the current state
3. **Walk through each tab**: Chat, Daily, Vault, Brain — tapping each and taking a screenshot
4. **Test Brain search**: Navigate to Brain tab, type "test" in the search field, wait for results
5. **Check Settings**: Navigate to settings, verify Bot Connectors and Hooks sections are visible
6. **Report findings** with screenshots

If Marionette is not available, skip this step and report:
> "Agentic testing skipped — Marionette MCP not connected. To enable: launch app with `flutter run -d macos`, note the VM service URI, and connect via Marionette."

## Step 3: Summary

Provide a summary:
- Total tests: X passed, Y failed
- Any regressions or new issues found
- Agentic test status
- Update `docs/test-plan.md` results log with today's date and results
