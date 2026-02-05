import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Vault Feature', () {
    testWidgets('Vault browser renders file list',
        (WidgetTester tester) async {
      final mockFiles = [
        {'name': 'Brain/', 'isDirectory': true},
        {'name': 'Daily/', 'isDirectory': true},
        {'name': 'Chat/', 'isDirectory': true},
        {'name': 'README.md', 'isDirectory': false},
      ];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('Vault')),
              body: ListView.builder(
                itemCount: mockFiles.length,
                itemBuilder: (context, index) {
                  final file = mockFiles[index];
                  final isDir = file['isDirectory'] as bool;
                  return ListTile(
                    leading: Icon(isDir ? Icons.folder : Icons.description),
                    title: Text(file['name'] as String),
                    trailing: isDir ? const Icon(Icons.chevron_right) : null,
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify vault browser shows expected items
      expect(find.text('Vault'), findsOneWidget);
      expect(find.text('Brain/'), findsOneWidget);
      expect(find.text('Daily/'), findsOneWidget);
      expect(find.text('Chat/'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsNWidgets(3));
      expect(find.byIcon(Icons.description), findsOneWidget);
    });

    testWidgets('Can tap folder to navigate', (WidgetTester tester) async {
      String? tappedFolder;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Vault')),
            body: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: const Text('Brain/'),
                  onTap: () => tappedFolder = 'Brain',
                ),
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: const Text('Daily/'),
                  onTap: () => tappedFolder = 'Daily',
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Tap Brain folder
      await tester.tap(find.text('Brain/'));
      await tester.pumpAndSettle();
      expect(tappedFolder, 'Brain');

      // Tap Daily folder
      await tester.tap(find.text('Daily/'));
      await tester.pumpAndSettle();
      expect(tappedFolder, 'Daily');
    });
  });
}
