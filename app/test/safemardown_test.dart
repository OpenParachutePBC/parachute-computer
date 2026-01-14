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

// Minimal version of _SafeMarkdownBody - just the wrapper
class MinimalSafeMarkdown extends StatefulWidget {
  final String text;

  const MinimalSafeMarkdown({super.key, required this.text});

  @override
  State<MinimalSafeMarkdown> createState() => _MinimalSafeMarkdownState();
}

class _MinimalSafeMarkdownState extends State<MinimalSafeMarkdown> {
  @override
  Widget build(BuildContext context) {
    return MarkdownBody(data: widget.text);
  }
}

// With post-frame callback
class SafeMarkdownWithCallback extends StatefulWidget {
  final String text;

  const SafeMarkdownWithCallback({super.key, required this.text});

  @override
  State<SafeMarkdownWithCallback> createState() => _SafeMarkdownWithCallbackState();
}

String? _trackingVar;

class _SafeMarkdownWithCallbackState extends State<SafeMarkdownWithCallback> {
  @override
  Widget build(BuildContext context) {
    _trackingVar = widget.text;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_trackingVar == widget.text) {
        _trackingVar = null;
      }
    });

    return MarkdownBody(data: widget.text);
  }
}

// With callback registration
class SafeMarkdownWithCallbackRegistration extends StatefulWidget {
  final String text;

  const SafeMarkdownWithCallbackRegistration({super.key, required this.text});

  @override
  State<SafeMarkdownWithCallbackRegistration> createState() => _SafeMarkdownWithCallbackRegistrationState();
}

final Map<int, VoidCallback> _callbacks = {};

class _SafeMarkdownWithCallbackRegistrationState extends State<SafeMarkdownWithCallbackRegistration> {
  @override
  void initState() {
    super.initState();
    _callbacks[widget.text.hashCode] = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _callbacks.remove(widget.text.hashCode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(data: widget.text);
  }
}

void main() {
  group('SafeMarkdown variations', () {
    testWidgets('1. Minimal wrapper - should pass', (tester) async {
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
                    body: MinimalSafeMarkdown(text: _testMarkdown),
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

    testWidgets('2. With post-frame callback', (tester) async {
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
                    body: SafeMarkdownWithCallback(text: _testMarkdown),
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

    testWidgets('3. With callback registration', (tester) async {
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
                    body: SafeMarkdownWithCallbackRegistration(text: _testMarkdown),
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
