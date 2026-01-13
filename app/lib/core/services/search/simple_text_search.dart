import 'package:flutter/foundation.dart';
import 'package:parachute/features/daily/journal/services/journal_service.dart';

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

/// Simple text search service using keyword matching
///
/// Provides instant search across journals without requiring
/// any model downloads or index building. Uses simple substring matching
/// with basic relevance scoring based on match count.
///
/// **Features:**
/// - No setup required - works immediately
/// - Searches journal entries
/// - Returns snippets with context around matches
/// - Basic relevance sorting by match count
///
/// **Limitations:**
/// - Only finds exact keyword matches (no semantic understanding)
/// - Performance scales linearly with vault size
/// - No fuzzy matching or stemming
class SimpleTextSearchService {
  final JournalService _journalService;

  SimpleTextSearchService({
    required JournalService journalService,
  }) : _journalService = journalService;

  /// Search across all journal entries using keyword matching
  ///
  /// Returns results sorted by relevance (match count).
  Future<List<SimpleSearchResult>> search(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];

    final queryLower = query.toLowerCase();
    final queryTerms = queryLower
        .split(RegExp(r'\s+'))
        .where((t) => t.length > 1)
        .toList();

    if (queryTerms.isEmpty) return [];

    debugPrint('[SimpleSearch] Searching for: "$query" (${queryTerms.length} terms)');
    final stopwatch = Stopwatch()..start();

    final results = await _searchJournals(queryLower, queryTerms);

    // Sort by match count (descending), then by date (newest first)
    results.sort((a, b) {
      final countCompare = b.matchCount.compareTo(a.matchCount);
      if (countCompare != 0) return countCompare;
      return b.date.compareTo(a.date);
    });

    stopwatch.stop();
    debugPrint(
      '[SimpleSearch] Found ${results.length} results in ${stopwatch.elapsedMilliseconds}ms',
    );

    return results.take(limit).toList();
  }

  /// Search journal entries (parallel loading for speed)
  Future<List<SimpleSearchResult>> _searchJournals(
    String queryLower,
    List<String> queryTerms,
  ) async {
    final results = <SimpleSearchResult>[];

    try {
      final dates = await _journalService.listJournalDates();

      // Load journals in parallel batches for speed
      const batchSize = 10;
      for (int i = 0; i < dates.length; i += batchSize) {
        final batch = dates.skip(i).take(batchSize).toList();
        final journals = await Future.wait(
          batch.map((date) => _journalService.loadDay(date)),
        );

        for (int j = 0; j < journals.length; j++) {
          final date = batch[j];
          final journal = journals[j];

          for (final entry in journal.entries) {
            if (entry.id == 'preamble' || entry.content.isEmpty) continue;

            final contentLower = entry.content.toLowerCase();
            final matchCount = _countMatches(contentLower, queryTerms);

            if (matchCount > 0) {
              final snippet = _extractSnippet(entry.content, queryLower, queryTerms);
              final dateStr = _formatDate(date);

              results.add(SimpleSearchResult(
                id: 'journal:$dateStr:${entry.id}',
                type: 'journal',
                title: entry.title.isNotEmpty ? entry.title : 'Entry',
                snippet: snippet,
                fullContent: entry.content,
                date: date,
                matchCount: matchCount,
                entryType: entry.type.name,
              ));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SimpleSearch] Error searching journals: $e');
    }

    return results;
  }

  /// Count how many query terms appear in the content
  int _countMatches(String contentLower, List<String> queryTerms) {
    int count = 0;
    for (final term in queryTerms) {
      // Count occurrences of this term
      int index = 0;
      while ((index = contentLower.indexOf(term, index)) != -1) {
        count++;
        index += term.length;
      }
    }
    return count;
  }

  /// Extract a snippet around the first match with context
  String _extractSnippet(
    String content,
    String queryLower,
    List<String> queryTerms,
  ) {
    final contentLower = content.toLowerCase();

    // Find first match position
    int firstMatchPos = content.length;
    for (final term in queryTerms) {
      final pos = contentLower.indexOf(term);
      if (pos != -1 && pos < firstMatchPos) {
        firstMatchPos = pos;
      }
    }

    if (firstMatchPos >= content.length) {
      // No match found (shouldn't happen), return beginning
      return content.substring(0, content.length.clamp(0, 200));
    }

    // Extract context around the match
    const contextChars = 80;
    final start = (firstMatchPos - contextChars).clamp(0, content.length);
    final end = (firstMatchPos + contextChars + 50).clamp(0, content.length);

    var snippet = content.substring(start, end);

    // Clean up the snippet
    snippet = snippet.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    // Add ellipsis if truncated
    if (start > 0) snippet = '...$snippet';
    if (end < content.length) snippet = '$snippet...';

    return snippet;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
