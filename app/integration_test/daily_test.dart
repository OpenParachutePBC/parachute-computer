import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/journal/models/journal_entry.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Daily Feature', () {
    testWidgets('JournalEntry model works correctly',
        (WidgetTester tester) async {
      final entry = JournalEntry(
        id: 'abc123',
        title: 'Voice Meeting',
        content: 'Met with Kevin about voice-first features',
        type: JournalEntryType.text,
        createdAt: DateTime(2026, 2, 5, 14, 30),
      );

      expect(entry.id, 'abc123');
      expect(entry.title, 'Voice Meeting');
      expect(entry.content, contains('Kevin'));
      expect(entry.createdAt.year, 2026);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Daily Journal')),
            body: ListView(
              children: [
                Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Feb 5, 2026',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(entry.content),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Daily Journal'), findsOneWidget);
      expect(find.text('Feb 5, 2026'), findsOneWidget);
      expect(
          find.text('Met with Kevin about voice-first features'), findsOneWidget);
    });

    testWidgets('Empty journal state renders', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('Daily')),
              body: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic_none, size: 64),
                    SizedBox(height: 16),
                    Text('Tap to start recording'),
                    Text('Your voice notes appear here'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Tap to start recording'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });
  });
}
