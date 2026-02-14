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

// Simulates _MessageContentWithCopy pattern - calls contentBuilder() during build
class WrapperWithContentBuilder extends StatefulWidget {
  final List<Widget> Function() contentBuilder;

  const WrapperWithContentBuilder({super.key, required this.contentBuilder});

  @override
  State<WrapperWithContentBuilder> createState() => _WrapperWithContentBuilderState();
}

class _WrapperWithContentBuilderState extends State<WrapperWithContentBuilder> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ...widget.contentBuilder(),  // This creates new widgets each build!
      ],
    );
  }
}

// Better pattern - passes widgets directly
class WrapperWithWidgets extends StatefulWidget {
  final List<Widget> children;

  const WrapperWithWidgets({super.key, required this.children});

  @override
  State<WrapperWithWidgets> createState() => _WrapperWithWidgetsState();
}

class _WrapperWithWidgetsState extends State<WrapperWithWidgets> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: widget.children,
    );
  }
}

void main() {
  group('Content builder pattern', () {
    testWidgets('FAILS: Using contentBuilder() pattern', (tester) async {
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
                    body: WrapperWithContentBuilder(
                      contentBuilder: () => [MarkdownBody(data: _testMarkdown)],
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
      print('contentBuilder pattern passed');
    });

    testWidgets('PASSES: Using direct children pattern', (tester) async {
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
                    body: WrapperWithWidgets(
                      children: [MarkdownBody(data: _testMarkdown)],
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
      print('direct children pattern passed');
    });
  });
}
