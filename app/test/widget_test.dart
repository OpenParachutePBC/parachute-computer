import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/theme/app_theme.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/features/chat/models/chat_session.dart';
import 'package:parachute/features/chat/models/stream_event.dart';

void main() {
  group('Design Tokens', () {
    test('Brand colors are defined', () {
      expect(BrandColors.forest, isA<Color>());
      expect(BrandColors.forest, isNotNull);
    });

    test('Design tokens define key brand colors', () {
      expect(BrandColors.forest, isA<Color>());
      expect(BrandColors.turquoise, isA<Color>());
      expect(BrandColors.cream, isA<Color>());
      expect(BrandColors.charcoal, isA<Color>());
    });
  });

  group('App State', () {
    test('AppMode enum has expected values', () {
      expect(AppMode.values, contains(AppMode.full));
      expect(AppMode.values, contains(AppMode.dailyOnly));
    });

    test('AppTab enum has expected values', () {
      expect(AppTab.values, contains(AppTab.chat));
      expect(AppTab.values, contains(AppTab.daily));
      expect(AppTab.values, contains(AppTab.vault));
    });
  });

  group('Chat Models', () {
    test('ChatSession creation', () {
      final session = ChatSession(
        id: 'test-session',
        title: 'Test Chat',
        createdAt: DateTime(2026, 2, 5),
        updatedAt: DateTime(2026, 2, 5),
      );

      expect(session.id, 'test-session');
      expect(session.title, 'Test Chat');
      expect(session.displayTitle, 'Test Chat');
    });

    test('ChatSession fromJson', () {
      final json = {
        'id': 'json-session',
        'title': 'From JSON',
        'createdAt': '2026-02-05T00:00:00.000Z',
        'updatedAt': '2026-02-05T00:00:00.000Z',
      };

      final session = ChatSession.fromJson(json);
      expect(session.id, 'json-session');
      expect(session.title, 'From JSON');
    });

    test('ChatSession source defaults to parachute', () {
      final session = ChatSession(
        id: 'src-test',
        createdAt: DateTime(2026, 2, 5),
      );
      expect(session.source, ChatSource.parachute);
      expect(session.isImported, false);
    });

    test('StreamEventType has all SSE types', () {
      final types = StreamEventType.values.map((e) => e.name).toList();
      expect(types, contains('session'));
      expect(types, contains('text'));
      expect(types, contains('thinking'));
      expect(types, contains('toolUse'));
      expect(types, contains('toolResult'));
      expect(types, contains('done'));
      expect(types, contains('error'));
      expect(types, contains('typedError'));
      expect(types, contains('userQuestion'));
    });
  });

  group('Widget Rendering', () {
    testWidgets('ProviderScope wraps app correctly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const Scaffold(
              body: Center(child: Text('Parachute Test')),
            ),
          ),
        ),
      );

      expect(find.text('Parachute Test'), findsOneWidget);
    });

    testWidgets('NavigationBar renders three destinations',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: NavigationBar(
              selectedIndex: 1,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  label: 'Chat',
                ),
                NavigationDestination(
                  icon: Icon(Icons.today_outlined),
                  label: 'Daily',
                ),
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  label: 'Vault',
                ),
              ],
            ),
            body: const Center(child: Text('Content')),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Vault'), findsOneWidget);
    });
  });
}
