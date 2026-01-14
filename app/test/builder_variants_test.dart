import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

const _testMarkdown = '''
## Summary

```bash
git push origin main
```
''';

// Simple builder - just returns a Container
class SimpleCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.tag != 'pre') return null;
    return Container(
      color: Colors.grey,
      padding: const EdgeInsets.all(8),
      child: Text(element.textContent),
    );
  }
}

// Builder with SelectableText
class SelectableCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.tag != 'pre') return null;
    return Container(
      color: Colors.grey,
      padding: const EdgeInsets.all(8),
      child: SelectableText(element.textContent),  // Uses SelectableText
    );
  }
}

// Builder with StatefulWidget
class StatefulCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.tag != 'pre') return null;
    return _StatefulCodeBlock(code: element.textContent);
  }
}

class _StatefulCodeBlock extends StatefulWidget {
  final String code;
  const _StatefulCodeBlock({required this.code});

  @override
  State<_StatefulCodeBlock> createState() => _StatefulCodeBlockState();
}

class _StatefulCodeBlockState extends State<_StatefulCodeBlock> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey,
      padding: const EdgeInsets.all(8),
      child: Text(widget.code),
    );
  }
}

void main() {
  group('Builder variants', () {
    testWidgets('Simple builder (no SelectableText)', (tester) async {
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
                        builders: {'pre': SimpleCodeBlockBuilder()},
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
      print('Simple builder passed');
    });

    testWidgets('SelectableText builder', (tester) async {
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
                        builders: {'pre': SelectableCodeBlockBuilder()},
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
      print('SelectableText builder passed');
    });

    testWidgets('Stateful builder', (tester) async {
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
                        builders: {'pre': StatefulCodeBlockBuilder()},
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
      print('Stateful builder passed');
    });
  });
}
