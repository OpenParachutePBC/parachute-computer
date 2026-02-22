import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Currently selected entity type tab.
///
/// Null means no tab selected (e.g., loading schemas).
final brainV2SelectedTypeProvider = StateProvider<String?>((ref) => null);

/// Current search query for filtering entities.
final brainV2SearchQueryProvider = StateProvider<String>((ref) => '');
