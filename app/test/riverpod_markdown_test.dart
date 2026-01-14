import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
  group('Riverpod + Markdown disposal', () {
    // Test 1: MarkdownBody inside ProviderScope
    testWidgets('MarkdownBody in ProviderScope with navigation', (tester) async {
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
                      child: MarkdownBody(data: _testMarkdown),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('MarkdownBody in ProviderScope rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away');
    });

    // Test 2: MarkdownBody WITHOUT ProviderScope (control)
    testWidgets('MarkdownBody WITHOUT ProviderScope - should pass', (tester) async {
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
                    child: MarkdownBody(data: _testMarkdown),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      print('MarkdownBody without ProviderScope rendered');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      print('Navigated away');
    });
  });
}
