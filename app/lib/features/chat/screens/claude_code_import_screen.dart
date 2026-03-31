import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/chat_service.dart';
import '../providers/chat_providers.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Screen for browsing and importing Claude Code sessions
/// Shows a flat list of recent sessions across all projects, sorted by date
class ClaudeCodeImportScreen extends ConsumerStatefulWidget {
  const ClaudeCodeImportScreen({super.key});

  @override
  ConsumerState<ClaudeCodeImportScreen> createState() =>
      _ClaudeCodeImportScreenState();
}

class _ClaudeCodeImportScreenState
    extends ConsumerState<ClaudeCodeImportScreen> {
  List<ClaudeCodeSession>? _sessions;
  List<ClaudeCodeSession>? _filteredSessions;
  List<ClaudeCodeProject>? _allProjects; // All projects from filesystem
  bool _isLoading = true;
  String? _error;
  final Set<String> _adoptingSessionIds = {};
  final Set<String> _adoptedSessionIds = {};
  final TextEditingController _searchController = TextEditingController();
  String? _selectedProject; // null = all projects

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(_filterSessions);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final service = ref.read(chatServiceProvider);
      // Load both sessions and all projects in parallel
      final results = await Future.wait([
        service.getRecentClaudeCodeSessions(limit: 500),
        service.getClaudeCodeProjects(),
      ]);

      if (mounted) {
        setState(() {
          _sessions = results[0] as List<ClaudeCodeSession>;
          _filteredSessions = _sessions;
          _allProjects = results[1] as List<ClaudeCodeProject>;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _filterSessions() {
    if (_sessions == null) return;

    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredSessions = _sessions!.where((session) {
        // Filter by project if selected
        if (_selectedProject != null &&
            session.projectPath != _selectedProject) {
          return false;
        }

        // Filter by search query
        if (query.isEmpty) return true;

        final title = session.displayTitle.toLowerCase();
        final project = session.projectPath?.toLowerCase() ?? '';
        final firstMsg = session.firstMessage?.toLowerCase() ?? '';

        return title.contains(query) ||
            project.contains(query) ||
            firstMsg.contains(query);
      }).toList();
    });
  }

  Future<void> _adoptSession(ClaudeCodeSession session) async {
    if (_adoptingSessionIds.contains(session.sessionId)) return;

    setState(() {
      _adoptingSessionIds.add(session.sessionId);
    });

    try {
      final service = ref.read(chatServiceProvider);
      final result = await service.adoptClaudeCodeSession(
        session.sessionId,
        projectPath: session.projectPath ?? session.cwd,
      );

      if (mounted) {
        setState(() {
          _adoptingSessionIds.remove(session.sessionId);
          if (result.success) {
            _adoptedSessionIds.add(session.sessionId);
          }
        });

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.alreadyAdopted
                  ? 'Session already in Parachute'
                  : 'Session imported! ${result.messageCount ?? 0} messages',
            ),
            backgroundColor:
                result.alreadyAdopted ? Colors.orange : Colors.green,
            action: result.success
                ? SnackBarAction(
                    label: 'Open',
                    textColor: Colors.white,
                    onPressed: () {
                      // Refresh sessions list and navigate to the session
                      ref.invalidate(chatSessionsProvider);
                      Navigator.of(context).pop(result.parachuteSessionId);
                    },
                  )
                : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _adoptingSessionIds.remove(session.sessionId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Continue Claude Code Session'),
        bottom: _selectedProject != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: _buildSelectedProjectBanner(isDark),
              )
            : null,
      ),
      body: Column(
        children: [
          // Search bar
          _buildSearchBar(isDark),

          // Content
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  Widget _buildSelectedProjectBanner(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      color: isDark
          ? BrandColors.nightTurquoise.withValues(alpha: 0.2)
          : BrandColors.turquoise.withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(
            Icons.folder,
            size: 16,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              _selectedProject!,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color:
                    isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () {
              setState(() {
                _selectedProject = null;
              });
              _filterSessions();
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : Colors.grey[50],
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.grey[800]! : Colors.grey[200]!,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search field
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by title, message, or path...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _searchController.clear();
                      },
                    )
                  : null,
              filled: true,
              fillColor: isDark ? Colors.grey[850] : Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
            ),
          ),

          // Project filter button (opens modal with all projects)
          if (_allProjects != null &&
              _allProjects!.isNotEmpty &&
              _selectedProject == null) ...[
            const SizedBox(height: Spacing.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_outlined, size: 18),
              label: Text('Filter by project (${_allProjects!.length})'),
              onPressed: () => _showProjectPicker(context, isDark),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _getShortProjectName(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return path;
    // Show last 2 parts for context
    if (parts.length <= 2) return parts.join('/');
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  void _showProjectPicker(BuildContext context, bool isDark) {
    final projects = _allProjects ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? BrandColors.nightSurface : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.grey[600] : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        color: isDark
                            ? BrandColors.nightTurquoise
                            : BrandColors.turquoise,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Text(
                        'Select Project (${projects.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Project list
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: projects.length,
                    itemBuilder: (context, index) {
                      final project = projects[index];
                      final shortName = _getShortProjectName(project.path);
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: isDark
                              ? BrandColors.nightTurquoise.withValues(alpha: 0.2)
                              : BrandColors.turquoise.withValues(alpha: 0.1),
                          child: Text(
                            '${project.sessionCount}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? BrandColors.nightTurquoise
                                  : BrandColors.turquoise,
                            ),
                          ),
                        ),
                        title: Text(
                          shortName,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          project.path,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: isDark ? Colors.grey[500] : Colors.grey[600],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          setState(() {
                            _selectedProject = project.path;
                          });
                          _loadSessionsForProject(project.path);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Load sessions for a specific project
  /// Fetches ALL sessions for that project (not just recent ones)
  Future<void> _loadSessionsForProject(String projectPath) async {
    setState(() {
      _isLoading = true;
    });

    try {
      final service = ref.read(chatServiceProvider);
      final projectSessions = await service.getClaudeCodeSessions(projectPath);

      if (mounted) {
        setState(() {
          _filteredSessions = projectSessions;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // Fall back to filtering existing sessions
          _filterSessions();
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildBody(bool isDark) {
    if (_error != null) {
      return _buildError(isDark);
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_filteredSessions == null || _filteredSessions!.isEmpty) {
      return _buildEmptyState(isDark);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Results count
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          child: Text(
            '${_filteredSessions!.length} sessions${_selectedProject != null ? ' in this project' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
          ),
        ),
        // Sessions list
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadData,
            child: ListView.builder(
              itemCount: _filteredSessions!.length,
              itemBuilder: (context, index) {
                final session = _filteredSessions![index];
                return _buildSessionTile(session, isDark);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: isDark ? Colors.red[300] : Colors.red,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Failed to load Claude Code sessions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: _loadData,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final hasSearch = _searchController.text.isNotEmpty;
    final hasFilter = _selectedProject != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasSearch || hasFilter
                  ? Icons.search_off
                  : Icons.terminal_outlined,
              size: 48,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
            const SizedBox(height: Spacing.md),
            Text(
              hasSearch || hasFilter
                  ? 'No matching sessions'
                  : 'No Claude Code sessions found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              hasSearch || hasFilter
                  ? 'Try a different search or filter'
                  : 'Use Claude Code in a project to create sessions',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                  ),
              textAlign: TextAlign.center,
            ),
            if (hasSearch || hasFilter) ...[
              const SizedBox(height: Spacing.lg),
              TextButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _selectedProject = null;
                  });
                  _filterSessions();
                },
                child: const Text('Clear filters'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(ClaudeCodeSession session, bool isDark) {
    final isAdopting = _adoptingSessionIds.contains(session.sessionId);
    final isAdopted = _adoptedSessionIds.contains(session.sessionId);
    final dateStr = _formatDate(session.lastTimestamp ?? session.createdAt);

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
      elevation: isDark ? 0 : 1,
      child: InkWell(
        onTap: isAdopted
            ? () {
                ref.invalidate(chatSessionsProvider);
                Navigator.of(context).pop(session.sessionId);
              }
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: model badge, title, action
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildModelBadge(session.shortModelName, isDark),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.displayTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? BrandColors.nightText
                                : BrandColors.charcoal,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              dateStr,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[600],
                              ),
                            ),
                            const SizedBox(width: Spacing.sm),
                            Text(
                              '${session.messageCount} msgs',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? Colors.grey[500]
                                    : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Action button
                  if (isAdopting)
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (isAdopted)
                    Icon(
                      Icons.check_circle,
                      color: isDark ? Colors.green[300] : Colors.green,
                      size: 28,
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Continue in Parachute',
                      onPressed: () => _adoptSession(session),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(4),
                    ),
                ],
              ),

              // Working directory (always show when not filtered by project)
              if (session.projectPath != null && _selectedProject == null) ...[
                const SizedBox(height: Spacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.grey[850]
                        : Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: isDark
                            ? BrandColors.nightTurquoise
                            : BrandColors.turquoise,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          session.projectPath!,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: isDark
                                ? Colors.grey[400]
                                : Colors.grey[700],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelBadge(String? modelName, bool isDark) {
    Color badgeColor;
    switch (modelName?.toLowerCase()) {
      case 'opus':
        badgeColor = Colors.purple;
        break;
      case 'sonnet':
        badgeColor = Colors.blue;
        break;
      case 'haiku':
        badgeColor = Colors.teal;
        break;
      default:
        badgeColor = Colors.grey;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          modelName?.substring(0, 1).toUpperCase() ?? '?',
          style: TextStyle(
            color: badgeColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Unknown date';
    final local = date.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${local.month}/${local.day}/${local.year}';
  }
}
