import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:parachute/features/chat/widgets/collapsible_code_block.dart';

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
  group('With builders', () {
    testWidgets('MarkdownBody with CollapsibleCodeBlockBuilder', (tester) async {
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
                      child: MarkdownBody(
                        data: _testMarkdown,
                        builders: {
                          'pre': CollapsibleCodeBlockBuilder(isDark: false),
                        },
                      ),
                    ),
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
      print('With builder passed');
    });

    testWidgets('MarkdownBody with imageBuilder callback', (tester) async {
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
                      child: MarkdownBody(
                        data: _testMarkdown,
                        // ignore: deprecated_member_use
                        imageBuilder: (uri, title, alt) => Container(),
                      ),
                    ),
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
      print('With imageBuilder passed');
    });

    testWidgets('MarkdownBody with onTapLink callback', (tester) async {
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
                      child: MarkdownBody(
                        data: _testMarkdown,
                        onTapLink: (text, href, title) {},
                      ),
                    ),
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
      print('With onTapLink passed');
    });

    testWidgets('MarkdownBody with styleSheet', (tester) async {
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
                      child: MarkdownBody(
                        data: _testMarkdown,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ),
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
      print('With styleSheet passed');
    });

    testWidgets('MarkdownBody with ALL options', (tester) async {
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
                      child: MarkdownBody(
                        data: _testMarkdown,
                        builders: {
                          'pre': CollapsibleCodeBlockBuilder(isDark: false),
                        },
                        // ignore: deprecated_member_use
                        imageBuilder: (uri, title, alt) => Container(),
                        onTapLink: (text, href, title) {},
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ),
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
      print('With ALL options passed');
    });
  });
}
