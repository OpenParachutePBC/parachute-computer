import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/features/brain/models/brain_entity.dart';
import 'package:parachute/features/brain/models/brain_search_result.dart';
import 'package:parachute/features/brain/screens/brain_screen.dart';
import 'package:parachute/features/brain/screens/brain_entity_screen.dart';
import 'package:parachute/features/brain/widgets/brain_tag_chip.dart';
import 'package:parachute/features/brain/widgets/brain_entity_card.dart';
import 'package:parachute/core/theme/app_theme.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Brain Models', () {
    testWidgets('BrainEntity parses from JSON', (WidgetTester tester) async {
      final entity = BrainEntity.fromJson({
        'para_id': 'abc-123',
        'name': 'Aaron Gabriel',
        'tags': ['person', 'founder'],
        'snippet': 'Building Parachute',
        'content': '# Aaron\nFounder of Parachute.',
        'path': 'Brain/entities/aaron-gabriel.md',
      });

      expect(entity.paraId, 'abc-123');
      expect(entity.name, 'Aaron Gabriel');
      expect(entity.tags, ['person', 'founder']);
      expect(entity.snippet, 'Building Parachute');
      expect(entity.content, contains('Founder'));
      expect(entity.path, contains('aaron-gabriel'));

      // Satisfy integration test runner
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('Model OK'))),
      ));
      await tester.pumpAndSettle();
    });

    testWidgets('BrainSearchResult parses from JSON',
        (WidgetTester tester) async {
      final result = BrainSearchResult.fromJson({
        'query': 'parachute',
        'count': 2,
        'results': [
          {'para_id': 'a', 'name': 'Parachute', 'tags': ['project'], 'snippet': 'Main project'},
          {'para_id': 'b', 'name': 'Parachute Daily', 'tags': ['app'], 'snippet': 'Journal app'},
        ],
      });

      expect(result.query, 'parachute');
      expect(result.count, 2);
      expect(result.results.length, 2);
      expect(result.results[0].name, 'Parachute');
      expect(result.results[1].tags, ['app']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('Search Model OK'))),
      ));
      await tester.pumpAndSettle();
    });
  });

  group('Brain Widgets', () {
    testWidgets('BrainTagChip renders tag text', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: BrainTagChip(tag: 'person')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('person'), findsOneWidget);
    });

    testWidgets('BrainEntityCard renders name, tags, snippet',
        (WidgetTester tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrainEntityCard(
              entity: const BrainEntity(
                paraId: 'test-1',
                name: 'Test Entity',
                tags: ['concept', 'test'],
                snippet: 'This is a test entity for integration testing.',
              ),
              onTap: () => tapped = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Entity'), findsOneWidget);
      expect(find.text('concept'), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
      expect(find.text('This is a test entity for integration testing.'), findsOneWidget);

      // Tap the card
      await tester.tap(find.text('Test Entity'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('Brain Screen', () {
    testWidgets('BrainScreen shows search field and empty state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiServerUrlProvider.overrideWith(
              (ref) async => 'http://localhost:9999',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const BrainScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Search field exists
      expect(find.byType(TextField), findsOneWidget);

      // Empty state
      expect(find.text('Search your Brain'), findsOneWidget);
      expect(find.text('Find people, projects, concepts, and more'), findsOneWidget);

      // Reload button in app bar
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('Search field accepts input', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiServerUrlProvider.overrideWith(
              (ref) async => 'http://localhost:9999',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const BrainScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Type into search field
      await tester.enterText(find.byType(TextField), 'parachute');
      // Wait for 300ms debounce to fire and update the provider
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Clear button appears (only shown when query provider is non-empty)
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });
  });

  group('Brain Entity Screen', () {
    testWidgets('BrainEntityScreen shows entity name in app bar',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiServerUrlProvider.overrideWith(
              (ref) async => 'http://localhost:9999',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const BrainEntityScreen(
              paraId: 'test-id',
              name: 'Test Entity',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Entity name in app bar
      expect(find.text('Test Entity'), findsOneWidget);
    });
  });
}
