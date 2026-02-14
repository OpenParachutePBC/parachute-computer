import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:parachute/features/chat/widgets/message_bubble.dart';
import 'package:parachute/features/chat/models/chat_message.dart';

const _testMarkdown = '''
## Summary

I've completed all the mock data page fixes:

### Pages Fixed
1. **Profile page** - Created `/api/profile` endpoint
2. **Live voting page** - Uses real sessions

### Test Results
**All 56 API tests pass!**

```bash
git push origin main
```
''';

void main() {
  group('MessageBubble isolation', () {
    // Test 1: Just MarkdownBody in ProviderScope - PASSES
    testWidgets('Raw MarkdownBody in ProviderScope', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    body: MarkdownBody(data: _testMarkdown),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Test 1 passed');
    });

    // Test 2: MessageBubble with simple text - test if it's the complex markdown
    testWidgets('MessageBubble with simple text', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: 'Hello world')],
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    body: MessageBubble(message: message),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Test 2 passed');
    });

    // Test 3: MessageBubble with complex markdown
    testWidgets('MessageBubble with complex markdown', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: _testMarkdown)],
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    body: MessageBubble(message: message),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Test 3 passed');
    });
  });
}
