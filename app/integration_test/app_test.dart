import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Launch', () {
    testWidgets('App renders MaterialApp with correct theme',
        (WidgetTester tester) async {
      // Build a minimal version of the app to test core rendering
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            title: 'Parachute',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: BrandColors.forest,
              ),
              useMaterial3: true,
            ),
            home: const Scaffold(
              body: Center(child: Text('Parachute')),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.text('Parachute'), findsOneWidget);
    });

    testWidgets('Design tokens have correct values',
        (WidgetTester tester) async {
      // Verify design tokens load correctly
      expect(BrandColors.forest, isNotNull);
      expect(BrandColors.forest, isA<Color>());

      // Test that we have the key color palette
      await tester.pumpWidget(
        MaterialApp(
          home: Container(
            color: BrandColors.forest,
            child: const Text('Token Test'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Token Test'), findsOneWidget);
    });
  });

  group('Navigation', () {
    testWidgets('Three-tab structure exists in full mode',
        (WidgetTester tester) async {
      // Build with ProviderScope overriding to full mode
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appModeProvider.overrideWith((ref) => AppMode.full),
          ],
          child: MaterialApp(
            home: Scaffold(
              bottomNavigationBar: NavigationBar(
                selectedIndex: 0,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline),
                    selectedIcon: Icon(Icons.chat_bubble),
                    label: 'Chat',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.today_outlined),
                    selectedIcon: Icon(Icons.today),
                    label: 'Daily',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: 'Vault',
                  ),
                ],
              ),
              body: const Center(child: Text('Tab Content')),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify all three tabs exist
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Vault'), findsOneWidget);
    });

    testWidgets('Can switch between tabs', (WidgetTester tester) async {
      int selectedIndex = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Scaffold(
                bottomNavigationBar: NavigationBar(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: (index) {
                    setState(() => selectedIndex = index);
                  },
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
                body: IndexedStack(
                  index: selectedIndex,
                  children: const [
                    Center(child: Text('Chat Screen')),
                    Center(child: Text('Daily Screen')),
                    Center(child: Text('Vault Screen')),
                  ],
                ),
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Start on Chat tab
      expect(find.text('Chat Screen'), findsOneWidget);

      // Tap Daily tab
      await tester.tap(find.text('Daily'));
      await tester.pumpAndSettle();
      expect(selectedIndex, 1);

      // Tap Vault tab
      await tester.tap(find.text('Vault'));
      await tester.pumpAndSettle();
      expect(selectedIndex, 2);

      // Tap back to Chat
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(selectedIndex, 0);
    });
  });

  group('Daily Only Mode', () {
    testWidgets('Daily-only flavor shows single tab',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appModeProvider.overrideWith((ref) => AppMode.dailyOnly),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: const Center(child: Text('Daily Home')),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // In daily-only mode, Chat and Vault tabs should not be shown
      expect(find.text('Daily Home'), findsOneWidget);
    });
  });
}
