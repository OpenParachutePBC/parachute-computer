---
status: pending
priority: p2
issue_id: 100
tags: [code-review, testing, quality]
dependencies: []
---

# Missing Integration Tests: No Automated Testing for Brain v2 Flows

## Problem Statement

Brain v2 Flutter UI has zero integration tests. All user flows (list → detail → edit → save → delete) are untested, making regressions likely and refactoring risky. No automated verification that the UI works end-to-end.

**Impact**: High risk of regressions. Manual testing required for every change. No CI/CD confidence. Breaking changes may not be caught until production.

## Findings

**Source**: pattern-recognition-specialist agent
**Confidence**: 95
**Evidence**:

```bash
$ find app/test -name "*brain_v2*"
# No results - zero test files

$ ls app/integration_test/
# Directory doesn't exist
```

**Critical Untested Flows**:
1. List entities → tap entity → view detail
2. Create new entity → fill form → save → verify created
3. Edit entity → update fields → save → verify updated
4. Delete entity → confirm → verify deleted
5. Search entities → verify filtered results
6. Navigation between entity types via tabs
7. Relationship chip tap → navigates to related entity

## Proposed Solutions

### Option 1: Add integration tests with flutter_test (Recommended)
**Implementation**:

```dart
// integration_test/brain_v2_flow_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parachute/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Brain v2 Entity Management', () {
    testWidgets('List entities and view detail', (tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Navigate to Brain tab
      await tester.tap(find.text('Brain'));
      await tester.pumpAndSettle();

      // Wait for entity list to load
      expect(find.byType(BrainV2EntityCard), findsWidgets);

      // Tap first entity
      await tester.tap(find.byType(BrainV2EntityCard).first);
      await tester.pumpAndSettle();

      // Verify detail screen loaded
      expect(find.byType(BrainV2EntityDetailScreen), findsOneWidget);
    });

    testWidgets('Create new entity', (tester) async {
      app.main();
      await tester.pumpAndSettle();

      // Navigate to Brain tab
      await tester.tap(find.text('Brain'));
      await tester.pumpAndSettle();

      // Tap create FAB
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Fill form
      await tester.enterText(find.byType(TextField).first, 'Test Entity');
      await tester.pumpAndSettle();

      // Submit
      await tester.tap(find.text('Create Person'));  // Or whatever entity type
      await tester.pumpAndSettle();

      // Verify success message
      expect(find.textContaining('Created entity'), findsOneWidget);
    });

    testWidgets('Update entity', (tester) async {
      // ... test edit flow
    });

    testWidgets('Delete entity', (tester) async {
      // ... test delete flow
    });

    testWidgets('Search entities', (tester) async {
      // ... test search flow
    });
  });
}
```

Run tests:
```bash
flutter test integration_test/brain_v2_flow_test.dart
```

**Pros**:
- Official Flutter integration testing
- Can run in CI/CD
- Catches regressions
- Documents expected behavior

**Cons**:
- Requires test data setup
- May need mock server

**Effort**: Large (6-8 hours for comprehensive coverage)
**Risk**: Low

### Option 2: Add widget tests only
**Implementation**: Test individual widgets in isolation

**Pros**:
- Faster to run
- Easier to write
- No full app needed

**Cons**:
- Doesn't test integration
- Misses navigation bugs
- Less confidence

**Effort**: Medium (4-5 hours)
**Risk**: Low

### Option 3: Manual test checklist only
**Implementation**: Document manual testing procedures

**Pros**:
- No code to write
- Quick to create

**Cons**:
- Not automated
- Error-prone
- Doesn't prevent regressions

**Effort**: Small (1 hour)
**Risk**: High

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `integration_test/brain_v2_flow_test.dart`
- Create: `integration_test/brain_v2_search_test.dart`
- Create: `integration_test/brain_v2_crud_test.dart`
- Modify: `pubspec.yaml` (add integration_test dependency)

**Test Coverage Goals**:
- [ ] Entity list loading
- [ ] Entity detail view
- [ ] Entity creation flow
- [ ] Entity editing flow
- [ ] Entity deletion flow
- [ ] Search functionality
- [ ] Tab navigation
- [ ] Relationship navigation
- [ ] Error states
- [ ] Loading states

**Test Data Strategy**:
- Use test database or mock server
- Create/cleanup test entities in setUp/tearDown
- Use factory pattern for test entity creation

**CI/CD Integration**:
```yaml
# .github/workflows/flutter_test.yml
- name: Run integration tests
  run: flutter test integration_test/
```

**Database Changes**: May need test database setup

**API Changes**: None

## Acceptance Criteria

- [ ] Integration test suite covers all critical flows
- [ ] Tests pass locally
- [ ] Tests run in CI/CD pipeline
- [ ] Test coverage report generated
- [ ] Documentation for running tests
- [ ] Test data setup/teardown automated

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Zero integration tests for Brain v2 UI
- **Source**: pattern-recognition-specialist agent (confidence: 95)
- **Pattern**: New features often ship without tests

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Flutter Testing**: https://docs.flutter.dev/testing/integration-tests
- **Integration Test Package**: https://pub.dev/packages/integration_test
- **Best Practices**: https://github.com/flutter/flutter/tree/main/packages/integration_test
