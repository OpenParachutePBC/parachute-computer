import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/brain_v2_schema.dart';
import 'brain_v2_service_provider.dart';

/// Load all available schemas from Brain v2.
///
/// Automatically fetches on first read.
final brainV2SchemaListProvider =
    FutureProvider.autoDispose<List<BrainV2Schema>>((ref) async {
  final service = ref.watch(brainV2ServiceProvider);
  if (service == null) return [];

  return service.listSchemas();
});
