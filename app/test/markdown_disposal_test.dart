import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
  group('Markdown disposal - minimal reproduction', () {
    // Test 1: Just MarkdownBody alone
    testWidgets('MarkdownBody renders and disposes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MarkdownBody(data: _lastMessage),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('MarkdownBody rendered');

      // Dispose by replacing with empty container
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      print('MarkdownBody disposed');
    });

    // Test 2: MarkdownBody with navigation
    testWidgets('MarkdownBody with Navigator.pop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
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
                    child: MarkdownBody(data: _lastMessage),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('Screen with MarkdownBody rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away');
    });

    // Test 3: MarkdownBody with selectable: true (uses Focus internally)
    testWidgets('MarkdownBody selectable with navigation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
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
                    child: MarkdownBody(
                      data: _lastMessage,
                      selectable: true,  // This adds SelectionArea/Focus
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('Selectable MarkdownBody rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away from selectable');
    });

    // Test 4: Nested Navigator (like the real app)
    testWidgets('MarkdownBody in nested Navigator with IndexedStack', (tester) async {
      int currentIndex = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                body: IndexedStack(
                  index: currentIndex,
                  children: [
                    // Tab 0: Chat with markdown
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
                            body: SingleChildScrollView(
                              child: MarkdownBody(data: _lastMessage),
                            ),
                          ),
                        );
                      },
                    ),
                    // Tab 1: Other screen
                    const Center(child: Text('Other Tab')),
                  ],
                ),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: currentIndex,
                  onTap: (index) => setState(() => currentIndex = index),
                  items: const [
                    BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
                    BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('Nested Navigator with IndexedStack rendered');

      // Navigate within the chat tab
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Popped within chat navigator');
    });

    // Test 5: Switch tabs while markdown is rendered
    testWidgets('Switch tabs with markdown rendered', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return DefaultTabController(
                length: 2,
                child: Scaffold(
                  body: TabBarView(
                    children: [
                      SingleChildScrollView(
                        child: MarkdownBody(data: _lastMessage),
                      ),
                      const Center(child: Text('Other Tab')),
                    ],
                  ),
                  bottomNavigationBar: const TabBar(
                    tabs: [
                      Tab(icon: Icon(Icons.chat)),
                      Tab(icon: Icon(Icons.home)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('TabBarView with markdown rendered');

      // Switch to other tab
      await tester.tap(find.byIcon(Icons.home));
      await tester.pumpAndSettle();
      print('Switched tabs');
    });
  });
}
