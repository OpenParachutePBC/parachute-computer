import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_schema.dart';
import 'brain_service_provider.dart';

/// Load all available schemas from Brain.
///
/// Automatically fetches on first read.
final brainSchemaListProvider =
    FutureProvider.autoDispose<List<BrainSchema>>((ref) async {
  final service = ref.watch(brainServiceProvider);
  if (service == null) return [];

  return service.listSchemas();
});
