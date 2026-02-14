import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';

import 'helpers/test_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Launch', () {
    testWidgets('App renders with correct theme', (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp());
      await tester.pumpAndSettle();

      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('Design tokens are valid', (WidgetTester tester) async {
      expect(BrandColors.forest, isNotNull);
      expect(BrandColors.forest, isA<Color>());
      expect(BrandColors.nightForest, isA<Color>());
      expect(BrandColors.turquoise, isA<Color>());
      expect(BrandColors.nightTurquoise, isA<Color>());

      await tester.pumpWidget(createTestApp());
      await tester.pumpAndSettle();
    });
  });

  group('Navigation — Full Mode', () {
    testWidgets('Full mode shows 4 navigation destinations',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.full));
      await tester.pumpAndSettle();

      // Navigation bar exists with all 4 destinations
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(4));
    });

    testWidgets('All tab labels present in navigation bar',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.full));
      await tester.pumpAndSettle();

      // Each label appears in the NavigationDestination widgets
      expect(find.text('Chat'), findsWidgets);
      expect(find.text('Daily'), findsWidgets);
      expect(find.text('Vault'), findsWidgets);
      expect(find.text('Brain'), findsWidgets);
    });

    testWidgets('Tapping tabs does not crash',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.full));
      await tester.pumpAndSettle();

      // Tap each tab — if we get through without exceptions, navigation works
      await tester.tap(find.text('Daily'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vault'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Brain'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();

      // Still have 4 destinations after all the tapping
      expect(find.byType(NavigationDestination), findsNWidgets(4));
    });

    testWidgets('Tab icons are correct', (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.full));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.byIcon(Icons.today_outlined), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.psychology_outlined), findsWidgets);
    });
  });

  group('Navigation — Daily Only Mode', () {
    testWidgets('Daily-only mode has no navigation bar',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.dailyOnly));
      await tester.pumpAndSettle();

      // No navigation bar (single tab doesn't need one)
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('No NavigationDestinations in daily-only mode',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestApp(mode: AppMode.dailyOnly));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationDestination), findsNothing);
    });
  });

  group('Dark Mode', () {
    testWidgets('App renders in dark mode without crash',
        (WidgetTester tester) async {
      await tester.pumpWidget(createTestAppDark(mode: AppMode.full));
      await tester.pumpAndSettle();

      // All 4 destinations render in dark mode
      expect(find.byType(NavigationDestination), findsNWidgets(4));
    });
  });
}
