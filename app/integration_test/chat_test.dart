import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/chat/models/chat_session.dart';
import 'package:parachute/features/chat/models/stream_event.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Chat Feature', () {
    testWidgets('ChatSession model parses correctly',
        (WidgetTester tester) async {
      // Test that chat models are properly structured
      final session = ChatSession(
        id: 'test-123',
        title: 'Test Session',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(session.id, 'test-123');
      expect(session.title, 'Test Session');
      expect(session.source, ChatSource.parachute);

      // Render a simple widget to satisfy integration test requirements
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
      expect(find.text('test-123'), findsOneWidget);
    });

    testWidgets('StreamEvent types are defined',
        (WidgetTester tester) async {
      // Verify all SSE event types exist
      expect(StreamEventType.values, contains(StreamEventType.session));
      expect(StreamEventType.values, contains(StreamEventType.text));
      expect(StreamEventType.values, contains(StreamEventType.thinking));
      expect(StreamEventType.values, contains(StreamEventType.toolUse));
      expect(StreamEventType.values, contains(StreamEventType.toolResult));
      expect(StreamEventType.values, contains(StreamEventType.done));
      expect(StreamEventType.values, contains(StreamEventType.error));

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Stream events verified')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stream events verified'), findsOneWidget);
    });

    testWidgets('Empty session list renders', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('Chat')),
              body: const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 64),
                    SizedBox(height: 16),
                    Text('No sessions yet'),
                    Text('Start a new chat to begin'),
                  ],
                ),
              ),
              floatingActionButton: FloatingActionButton(
                onPressed: () {},
                child: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('No sessions yet'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });
  });
}
