import 'brain_entity.dart';

/// Result from a Brain search query.
class BrainSearchResult {
  final String query;
  final int count;
  final List<BrainEntity> results;

  const BrainSearchResult({
    required this.query,
    required this.count,
    required this.results,
  });

  factory BrainSearchResult.fromJson(Map<String, dynamic> json) {
    return BrainSearchResult(
      query: json['query'] as String? ?? '',
      count: json['count'] as int? ?? 0,
      results: (json['results'] as List<dynamic>?)
              ?.map((e) => BrainEntity.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
