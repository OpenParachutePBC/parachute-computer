import 'package:flutter/foundation.dart';
import '../../journal/services/daily_api_service.dart';

/// Simple text search result
class SimpleSearchResult {
  /// Unique identifier for this result
  final String id;

  /// Type of content: 'journal'
  final String type;

  /// Title or identifier for display (e.g., "10:30 AM" for journal entries)
  final String title;

  /// The matching text snippet
  final String snippet;

  /// The full text content (for "Ask AI" context)
  final String fullContent;

  /// Date associated with this content
  final DateTime date;

  /// Number of keyword matches
  final int matchCount;

  /// Entry type indicator (voice, text, photo, etc.)
  final String? entryType;

  /// Similarity score for semantic search (0.0 to 1.0)
  final double? similarityScore;

  SimpleSearchResult({
    required this.id,
    required this.type,
    required this.title,
    required this.snippet,
    required this.fullContent,
    required this.date,
    required this.matchCount,
    this.entryType,
    this.similarityScore,
  });

  /// Format date for display (e.g., "Jan 10, 2025")
  String get formattedDate {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

/// Simple text search service using keyword matching.
///
/// Delegates search to the server API (`GET /api/daily/entries/search`)
/// and maps the results to [SimpleSearchResult] for display.
class SimpleTextSearchService {
  final DailyApiService _apiService;

  SimpleTextSearchService({required DailyApiService apiService})
      : _apiService = apiService;

  /// Search across all journal entries using keyword matching.
  ///
  /// Returns results sorted by relevance (match count).
  Future<List<SimpleSearchResult>> search(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];

    debugPrint('[SimpleSearch] Searching for: "$query"');
    final stopwatch = Stopwatch()..start();

    try {
      final apiResults = await _apiService.searchEntries(query, limit: limit);

      final results = apiResults.map((r) {
        final meta = r.metadata;
        final title = meta['title'] as String? ?? '';
        final typeStr = meta['type'] as String? ?? 'text';
        final createdAt = _parseDate(r.createdAt);

        return SimpleSearchResult(
          id: r.id,
          type: 'journal',
          title: title.isNotEmpty ? title : 'Entry',
          snippet: r.snippet,
          fullContent: r.content,
          date: createdAt,
          matchCount: r.matchCount,
          entryType: typeStr,
        );
      }).toList();

      stopwatch.stop();
      debugPrint(
        '[SimpleSearch] Found ${results.length} results in ${stopwatch.elapsedMilliseconds}ms',
      );

      return results;
    } catch (e) {
      debugPrint('[SimpleSearch] Error: $e');
      return [];
    }
  }

  DateTime _parseDate(String iso) {
    if (iso.isEmpty) return DateTime.now();
    try {
      return DateTime.parse(iso).toLocal();
    } catch (_) {
      return DateTime.now();
    }
  }
}
