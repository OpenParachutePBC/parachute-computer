import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/theme/app_theme.dart';
import 'package:parachute/features/settings/widgets/bot_connectors_section.dart';
import 'package:parachute/features/settings/widgets/hooks_section.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Bot Connectors Section', () {
    testWidgets('BotConnectorsSection renders header',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiServerUrlProvider.overrideWith(
              (ref) async => 'http://localhost:9999',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: BotConnectorsSection(),
                ),
              ),
            ),
          ),
        ),
      );
      // Don't pumpAndSettle — the HTTP call will fail/timeout,
      // just pump a few frames to render the loading state
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Section header renders
      expect(find.text('Bot Connectors'), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
    });
  });

  group('Hooks Section', () {
    testWidgets('HooksSection renders header', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiServerUrlProvider.overrideWith(
              (ref) async => 'http://localhost:9999',
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: HooksSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Section header renders
      expect(find.text('Hooks'), findsOneWidget);
      expect(find.byIcon(Icons.webhook_outlined), findsOneWidget);
    });
  });

  group('Settings Structure', () {
    testWidgets('New settings sections are ConsumerStatefulWidgets',
        (WidgetTester tester) async {
      // Verify the widgets can be constructed and are the right type
      const botSection = BotConnectorsSection();
      const hooksSection = HooksSection();

      expect(botSection, isA<ConsumerStatefulWidget>());
      expect(hooksSection, isA<ConsumerStatefulWidget>());

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('Structure OK'))),
      ));
      await tester.pumpAndSettle();
    });
  });
}
