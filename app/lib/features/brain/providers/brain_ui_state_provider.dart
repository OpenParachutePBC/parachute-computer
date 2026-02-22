import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Currently selected entity type tab.
///
/// Null means no tab selected (e.g., loading schemas).
final brainSelectedTypeProvider = StateProvider<String?>((ref) => null);

/// Current search query for filtering entities.
final brainSearchQueryProvider = StateProvider<String>((ref) => '');
