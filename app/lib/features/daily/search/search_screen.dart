import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/search_providers.dart';
import 'package:parachute/core/services/search/simple_text_search.dart';

/// Search screen for keyword search across journal entries
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _performSearch() {
    final query = _searchController.text.trim();
    ref.read(searchProvider.notifier).search(query);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final searchState = ref.watch(searchProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: const Text('Search'),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Search input
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              decoration: InputDecoration(
                hintText: 'Search your journal...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searchState.query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(searchProvider.notifier).clear();
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDark
                    ? BrandColors.nightSurfaceElevated
                    : Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onChanged: (_) => _performSearch(),
              onSubmitted: (_) => _performSearch(),
            ),
          ),

          // Results or placeholder
          Expanded(
            child: _buildContent(searchState, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(SearchState searchState, bool isDark) {
    // Loading state
    if (searchState.isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Error state
    if (searchState.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: 16),
            Text(
              searchState.error!,
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Empty query - show placeholder
    if (searchState.query.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
            const SizedBox(height: 16),
            Text(
              'Search your journal entries',
              style: TextStyle(
                fontSize: 18,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Type keywords to find matching entries',
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                    : BrandColors.driftwood.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    // No results
    if (searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
            const SizedBox(height: 16),
            Text(
              'No results found',
              style: TextStyle(
                fontSize: 18,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try different keywords',
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                    : BrandColors.driftwood.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    // Results list
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: searchState.results.length,
      itemBuilder: (context, index) {
        final result = searchState.results[index];
        return _SearchResultCard(
          result: result,
          query: searchState.query,
          isDark: isDark,
        );
      },
    );
  }
}

/// Card displaying a single search result
class _SearchResultCard extends StatelessWidget {
  final SimpleSearchResult result;
  final String query;
  final bool isDark;

  const _SearchResultCard({
    required this.result,
    required this.query,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
      elevation: isDark ? 0 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isDark
            ? BorderSide(color: BrandColors.nightSurfaceElevated, width: 1)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () {
          // TODO: Navigate to journal entry
          debugPrint('[Search] Tapped: ${result.id}');
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row with time and date
              Row(
                children: [
                  // Entry type icon
                  Icon(
                    _getEntryTypeIcon(result.entryType),
                    size: 16,
                    color: isDark
                        ? BrandColors.nightTurquoise
                        : BrandColors.turquoise,
                  ),
                  const SizedBox(width: 8),
                  // Time (from entry title, e.g., "10:30 AM")
                  Text(
                    result.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? BrandColors.nightText
                          : BrandColors.charcoal,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Date
                  Text(
                    result.formattedDate,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                  ),
                  const Spacer(),
                  // Match count or similarity score
                  if (result.similarityScore != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? BrandColors.nightForest.withValues(alpha: 0.2)
                            : BrandColors.forest.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${(result.similarityScore! * 100).toInt()}% match',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? BrandColors.nightTurquoise.withValues(alpha: 0.2)
                            : BrandColors.success.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${result.matchCount} match${result.matchCount > 1 ? 'es' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? BrandColors.nightTurquoise
                              : BrandColors.success,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Snippet with highlighted matches
              _HighlightedText(
                text: result.snippet,
                query: query,
                isDark: isDark,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Get icon for entry type
  IconData _getEntryTypeIcon(String? entryType) {
    switch (entryType) {
      case 'voice':
        return Icons.mic;
      case 'text':
        return Icons.edit_note;
      case 'photo':
        return Icons.photo_camera;
      case 'handwriting':
        return Icons.draw;
      case 'linked':
        return Icons.link;
      default:
        return Icons.article;
    }
  }
}

/// Text widget that highlights matching query terms
class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final bool isDark;

  const _HighlightedText({
    required this.text,
    required this.query,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final queryTerms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.length > 1).toList();
    if (queryTerms.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
        ),
      );
    }

    // Build spans with highlighting
    final spans = <TextSpan>[];
    final textLower = text.toLowerCase();
    int currentIndex = 0;

    // Find all match positions
    final matches = <({int start, int end})>[];
    for (final term in queryTerms) {
      int index = 0;
      while ((index = textLower.indexOf(term, index)) != -1) {
        matches.add((start: index, end: index + term.length));
        index += term.length;
      }
    }

    // Sort matches by start position and merge overlapping
    matches.sort((a, b) => a.start.compareTo(b.start));
    final mergedMatches = <({int start, int end})>[];
    for (final match in matches) {
      if (mergedMatches.isEmpty || match.start > mergedMatches.last.end) {
        mergedMatches.add(match);
      } else {
        final last = mergedMatches.removeLast();
        mergedMatches.add((
          start: last.start,
          end: match.end > last.end ? match.end : last.end,
        ));
      }
    }

    // Build text spans
    for (final match in mergedMatches) {
      // Add non-matching text before this match
      if (match.start > currentIndex) {
        spans.add(TextSpan(
          text: text.substring(currentIndex, match.start),
          style: TextStyle(
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
          ),
        ));
      }
      // Add highlighted match
      spans.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(
          color: isDark ? BrandColors.nightTurquoise : BrandColors.success,
          fontWeight: FontWeight.w600,
          backgroundColor: isDark
              ? BrandColors.nightTurquoise.withValues(alpha: 0.15)
              : BrandColors.success.withValues(alpha: 0.15),
        ),
      ));
      currentIndex = match.end;
    }

    // Add remaining text
    if (currentIndex < text.length) {
      spans.add(TextSpan(
        text: text.substring(currentIndex),
        style: TextStyle(
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
        ),
      ));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 14),
        children: spans,
      ),
    );
  }
}
