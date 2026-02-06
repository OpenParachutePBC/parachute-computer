import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/chat/models/chat_session.dart';
import 'package:parachute/features/chat/models/stream_event.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Chat Models', () {
    testWidgets('ChatSession model parses correctly',
        (WidgetTester tester) async {
      final session = ChatSession(
        id: 'test-123',
        title: 'Test Session',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(session.id, 'test-123');
      expect(session.title, 'Test Session');
      expect(session.displayTitle, 'Test Session');
      expect(session.source, ChatSource.parachute);

      // Nullable title
      final untitled = ChatSession(
        id: 'test-456',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(untitled.title, isNull);
      expect(untitled.displayTitle, isNotEmpty); // Falls back to a default

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ListTile(
                  title: Text(session.displayTitle),
                  subtitle: Text(session.id),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Test Session'), findsOneWidget);
    });

    testWidgets('StreamEventType has all expected values',
        (WidgetTester tester) async {
      // Core event types
      expect(StreamEventType.values, contains(StreamEventType.session));
      expect(StreamEventType.values, contains(StreamEventType.text));
      expect(StreamEventType.values, contains(StreamEventType.thinking));
      expect(StreamEventType.values, contains(StreamEventType.toolUse));
      expect(StreamEventType.values, contains(StreamEventType.toolResult));
      expect(StreamEventType.values, contains(StreamEventType.done));
      expect(StreamEventType.values, contains(StreamEventType.error));

      // Extended event types added in later phases
      expect(StreamEventType.values, contains(StreamEventType.typedError));
      expect(StreamEventType.values, contains(StreamEventType.userQuestion));
      expect(StreamEventType.values, contains(StreamEventType.promptMetadata));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Stream events verified')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
  });
}
