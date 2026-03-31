import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parachute/features/daily/journal/models/journal_entry.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Daily Models', () {
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
      expect(entry.type, JournalEntryType.text);
      expect(entry.createdAt.year, 2026);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.title,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
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
      expect(find.text('Voice Meeting'), findsOneWidget);
      expect(find.text('Met with Kevin about voice-first features'), findsOneWidget);
    });

    testWidgets('JournalEntryType enum has expected values',
        (WidgetTester tester) async {
      expect(JournalEntryType.values, contains(JournalEntryType.text));
      expect(JournalEntryType.values, contains(JournalEntryType.voice));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Types OK'))),
        ),
      );
      await tester.pumpAndSettle();
    });
  });
}
