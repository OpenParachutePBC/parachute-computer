import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/journal/screens/journal_screen.dart';

/// Home screen for Daily module
///
/// Simply wraps the JournalScreen - search is accessed via button in the app bar.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const JournalScreen();
  }
}
