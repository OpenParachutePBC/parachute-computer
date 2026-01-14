import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/chat/widgets/message_bubble.dart';
import 'package:parachute/features/chat/widgets/chat_input.dart';
import 'package:parachute/features/chat/models/chat_message.dart';

// The exact last message from Community Murmur chat
const _lastMessage = '''
The push requires authentication. Let me summarize what was done:

---

## Summary

I've completed all the mock data page fixes and testing improvements:

### Pages Fixed (using real API data)
1. **Profile page** - Created `/api/profile` endpoint and `use-profile` hook
2. **Live voting page** - Uses real sessions, time slots, and votes
3. **Admin distribution page** - Uses real event budget and session stats
4. **Admin participants page** - Uses real participant data with check-in status
5. **Admin mergers page** - Created mergers API (`/api/events/:slug/mergers`) and `use-mergers` hook

### Test Fixes
- Updated `seed.sql` to use `ethboulder-2026` event slug with 2026 dates
- Fixed test-utils to use port 3000 (Next.js default)
- Fixed API helpers to use correct endpoint paths (`/access/grant` instead of `/access`)
- Updated time-slots tests to use camelCase field names (`startTime` vs `start_time`)
- Made session detail test more flexible

### Test Results
**All 56 API tests pass!**

### Commits (not pushed yet - needs authentication)
```
793d871 Fix E2E tests and update seed data for ethboulder-2026
964bf8a Add mergers API and fix test event slug
dafdd1d Fix admin pages to use real data
422d98d Add profile API and fix live voting page
3365955 Replace mock data with real API calls in event pages
```

To push these changes, you'll need to run:
```bash
git push origin main
```

Or if using SSH:
```bash
git remote set-url origin git@github.com:RegenHub-Boulder/schellingpointapp.git
git push origin main
```
''';

void main() {
  group('Full chat widget tree disposal', () {
    // Test with actual MessageBubble widget
    testWidgets('MessageBubble with navigation', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: _lastMessage)],
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
                    body: SingleChildScrollView(
                      child: MessageBubble(message: message),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('MessageBubble rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away');
    });

    // Test with MessageBubble + ChatInput (like real chat screen)
    testWidgets('MessageBubble + ChatInput with navigation', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: _lastMessage)],
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
                    body: Column(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: MessageBubble(message: message),
                          ),
                        ),
                        ChatInput(
                          onSend: (text, attachments) {},
                          enabled: true,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('MessageBubble + ChatInput rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away');
    });

    // Test with nested Navigator + IndexedStack (like real app)
    testWidgets('Full nested Navigator structure', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: _lastMessage)],
        timestamp: DateTime.now(),
      );

      int currentTab = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                return Scaffold(
                  body: IndexedStack(
                    index: currentTab,
                    children: [
                      // Chat tab
                      Navigator(
                        onGenerateRoute: (settings) {
                          return MaterialPageRoute(
                            builder: (context) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Chat'),
                                leading: IconButton(
                                  icon: const Icon(Icons.arrow_back),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ),
                              body: Column(
                                children: [
                                  Expanded(
                                    child: SingleChildScrollView(
                                      child: MessageBubble(message: message),
                                    ),
                                  ),
                                  ChatInput(
                                    onSend: (text, attachments) {},
                                    enabled: true,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      // Other tab
                      const Center(child: Text('Daily')),
                    ],
                  ),
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: currentTab,
                    onDestinationSelected: (index) {
                      setState(() => currentTab = index);
                    },
                    destinations: const [
                      NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
                      NavigationDestination(icon: Icon(Icons.today), label: 'Daily'),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('Full nested structure rendered');

      // Pop within the chat navigator
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Popped chat screen');
    });

    // Test focusing text field then navigating
    testWidgets('Focus ChatInput then navigate', (tester) async {
      final message = ChatMessage(
        id: '1',
        sessionId: 'test-session',
        role: MessageRole.assistant,
        content: [MessageContent(type: ContentType.text, text: _lastMessage)],
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
                    body: Column(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            child: MessageBubble(message: message),
                          ),
                        ),
                        ChatInput(
                          onSend: (text, attachments) {},
                          enabled: true,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Focus the text field
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      print('TextField focused');

      // Navigate while focused
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated while focused');
    });
  });
}
