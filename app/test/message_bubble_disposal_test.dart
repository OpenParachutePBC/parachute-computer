import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parachute/features/chat/widgets/message_bubble.dart';
import 'package:parachute/features/chat/models/chat_message.dart';

void main() {
  group('MessageBubble disposal', () {
    testWidgets('disposes cleanly when navigating away', (tester) async {
      // Create test messages similar to Community Murmur
      final messages = [
        ChatMessage(
          id: '1',
          sessionId: 'test-session',
          role: MessageRole.user,
          content: [MessageContent(type: ContentType.text, text: 'Hello')],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '2',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: '''
Here is a response with markdown:

---

## Summary

Some content after horizontal rule and header.
''')],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '3',
          sessionId: 'test-session',
          role: MessageRole.user, 
          content: [MessageContent(type: ContentType.text, text: 'Another message')],
          timestamp: DateTime.now(),
        ),
      ];

      // Build the chat screen
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              itemCount: messages.length,
              itemBuilder: (context, index) {
                return MessageBubble(
                  message: messages[index],
                  vaultPath: '/tmp/test',
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('Messages rendered: ${messages.length}');

      // Now navigate away by replacing with empty screen
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Empty')),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('Navigation complete');
    });

    testWidgets('handles rapid rebuilds during streaming', (tester) async {
      var messageText = 'Initial';
      
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: MessageBubble(
                  message: ChatMessage(
                    id: '1',
                    sessionId: 'test-session',
                    role: MessageRole.assistant,
                    content: [MessageContent(type: ContentType.text, text: messageText)],
                    timestamp: DateTime.now(),
                    isStreaming: true,
                  ),
                  vaultPath: '/tmp/test',
                ),
                floatingActionButton: FloatingActionButton(
                  onPressed: () {
                    setState(() {
                      messageText += ' more text';
                    });
                  },
                  child: Icon(Icons.add),
                ),
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Simulate streaming by rapidly updating
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pump(Duration(milliseconds: 50));
      }

      await tester.pumpAndSettle();
      print('Streaming simulation complete');

      // Navigate away during "streaming"
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Text('Gone')),
        ),
      );

      await tester.pumpAndSettle();
      print('Disposed during streaming');
    });
  });
}
