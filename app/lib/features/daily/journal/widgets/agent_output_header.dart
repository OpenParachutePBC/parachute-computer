import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/agent_card.dart';
import '../utils/agent_theme.dart';
import '../screens/agent_log_screen.dart';

/// Expandable header showing output from a daily agent
///
/// Accepts an [AgentCard] from the graph — no vault-file dependencies.
class AgentOutputHeader extends StatefulWidget {
  final AgentCard card;
  final bool initiallyExpanded;

  /// Called when an unread card is collapsed (expanded → collapsed).
  /// The parent should fire the mark-read API and update local state.
  final void Function(String cardId)? onMarkRead;

  const AgentOutputHeader({
    super.key,
    required this.card,
    this.initiallyExpanded = false,
    this.onMarkRead,
  });

  @override
  State<AgentOutputHeader> createState() => _AgentOutputHeaderState();
}

class _AgentOutputHeaderState extends State<AgentOutputHeader>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _controller;
  late Animation<double> _heightFactor;
  late Animation<double> _iconRotation;
  late String _preview;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _preview = _contentPreview(widget.card.content);
    _controller = AnimationController(
      duration: Motion.gentle,
      vsync: this,
    );
    _heightFactor = _controller.drive(CurveTween(curve: Curves.easeInOut));
    _iconRotation = _controller.drive(Tween(begin: 0.0, end: 0.5));

    if (_isExpanded) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(AgentOutputHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.content != widget.card.content) {
      _preview = _contentPreview(widget.card.content);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    final wasExpanded = _isExpanded;
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
    // Mark read on collapse (not expand) — handles accidental taps
    if (wasExpanded && widget.card.isUnread) {
      widget.onMarkRead?.call(widget.card.cardId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Get theming for this agent
    final agentTheme = AgentTheme.forAgent(widget.card.agentName);
    final icon = agentTheme.icon;
    final color = agentTheme.color;

    final isUnread = widget.card.isUnread;

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  BrandColors.nightSurfaceElevated,
                  BrandColors.nightSurface,
                ]
              : isUnread
                  ? [
                      color.withValues(alpha: 0.14),
                      color.withValues(alpha: 0.04),
                    ]
                  : [
                      color.withValues(alpha: 0.1),
                      BrandColors.softWhite,
                    ],
        ),
        borderRadius: Radii.card,
        border: Border.all(
          color: isDark
              ? color.withValues(alpha: isUnread ? 0.45 : 0.3)
              : color.withValues(alpha: isUnread ? 0.35 : 0.2),
        ),
        boxShadow: isDark ? null : Elevation.cardShadow,
      ),
      child: Column(
        children: [
          // Header (always visible, tappable)
          InkWell(
            onTap: _toggle,
            borderRadius: Radii.card,
            child: Padding(
              padding: EdgeInsets.all(Spacing.lg),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Icon(
                      icon,
                      size: 24,
                      color: color,
                    ),
                  ),
                  SizedBox(width: Spacing.md + Spacing.xxs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (isUnread) ...[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                widget.card.displayName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isExpanded
                              ? 'Tap to collapse'
                              : _preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // View log button - shows agent session transcript
                  IconButton(
                    icon: Icon(
                      Icons.history,
                      size: 20,
                      color: BrandColors.driftwood,
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => AgentLogScreen(
                            agentName: widget.card.agentName,
                            displayName: widget.card.displayName,
                          ),
                        ),
                      );
                    },
                    tooltip: 'View ${widget.card.displayName} log',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  SizedBox(width: Spacing.sm),
                  RotationTransition(
                    turns: _iconRotation,
                    child: Icon(
                      Icons.expand_more,
                      color: BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expandable content
          ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Align(
                alignment: Alignment.topCenter,
                heightFactor: _heightFactor.value,
                child: child,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  Spacing.lg, 0, Spacing.lg, Spacing.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(
                      color: isDark
                          ? BrandColors.charcoal.withValues(alpha: 0.5)
                          : BrandColors.stone.withValues(alpha: 0.5),
                    ),
                    SizedBox(height: Spacing.sm),
                    MarkdownBody(
                      data: widget.card.content,
                      selectable: true,
                      imageBuilder: (uri, title, alt) => _buildImage(
                        uri, title, alt, '', isDark,
                      ),
                      onTapLink: (text, href, title) => _handleLinkTap(
                        context, text, href, title, '',
                      ),
                      styleSheet: MarkdownStyleSheet(
                        p: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          height: 1.6,
                        ),
                        h1: theme.textTheme.titleLarge?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        h2: theme.textTheme.titleMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        h3: theme.textTheme.titleSmall?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        blockquote: theme.textTheme.bodyMedium?.copyWith(
                          color: BrandColors.driftwood,
                          fontStyle: FontStyle.italic,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: color.withValues(alpha: 0.5),
                              width: 3,
                            ),
                          ),
                        ),
                        code: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          backgroundColor: isDark
                              ? BrandColors.charcoal.withValues(alpha: 0.5)
                              : BrandColors.stone.withValues(alpha: 0.3),
                        ),
                        a: theme.textTheme.bodyMedium?.copyWith(
                          color: BrandColors.turquoise,
                          decoration: TextDecoration.underline,
                        ),
                        listBullet: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                        ),
                        strong: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        em: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Extract a plain-text preview from markdown content.
  String _contentPreview(String markdown) {
    // Strip markdown syntax for a clean preview line
    final stripped = markdown
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '') // headings
        .replaceAll(RegExp(r'\*{1,2}([^*]+)\*{1,2}'), r'$1') // bold/italic
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1') // inline code
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1') // links
        .replaceAll(RegExp(r'^\s*[-*>]\s+', multiLine: true), '') // bullets/quotes
        .replaceAll(RegExp(r'\n+'), ' ') // collapse newlines
        .trim();
    return stripped.isEmpty ? 'Tap to read' : stripped;
  }

  /// Resolve a relative asset path to an absolute path
  String? _resolveAssetPath(String path, String basePath) {
    if (basePath.isEmpty) return null;

    // Already absolute
    if (path.startsWith('/')) return path;

    // Remove leading ./ if present
    final cleanPath = path.startsWith('./') ? path.substring(2) : path;

    // Handle ../ relative paths (go up from output dir to Daily dir)
    if (cleanPath.startsWith('../')) {
      final parentPath = Directory(basePath).parent.path;
      final relativePart = cleanPath.substring(3); // Remove ../
      return '$parentPath/$relativePart';
    }

    return '$basePath/$cleanPath';
  }

  /// Build an inline image widget
  Widget _buildImage(Uri uri, String? title, String? alt, String basePath, bool isDark) {
    final uriString = uri.toString();

    // Check if it's a remote URL
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            uriString,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) =>
                _buildImagePlaceholder(alt ?? 'Failed to load image', isDark),
          ),
        ),
      );
    }

    // Handle local file paths
    final path = _resolveAssetPath(uriString, basePath);
    if (path == null) {
      return _buildImagePlaceholder(alt ?? 'Image', isDark);
    }

    return FutureBuilder<bool>(
      future: File(path).exists(),
      builder: (context, snapshot) {
        if (snapshot.data != true) {
          // Try alternate extensions
          return _buildImageWithFallbacks(path, alt, isDark);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  _buildImagePlaceholder('Failed to load image', isDark),
            ),
          ),
        );
      },
    );
  }

  /// Try to find image with alternate extensions
  Widget _buildImageWithFallbacks(String path, String? alt, bool isDark) {
    final alternateExtensions = ['.jpeg', '.jpg', '.png', '.webp'];
    final basePath = path.replaceAll(RegExp(r'\.[^.]+$'), '');

    return FutureBuilder<File?>(
      future: _findImageFile(basePath, alternateExtensions),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return _buildImagePlaceholder(alt ?? 'Image not found', isDark);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  _buildImagePlaceholder('Failed to load image', isDark),
            ),
          ),
        );
      },
    );
  }

  Future<File?> _findImageFile(String basePath, List<String> extensions) async {
    for (final ext in extensions) {
      final file = File('$basePath$ext');
      if (await file.exists()) {
        return file;
      }
    }
    return null;
  }

  Widget _buildImagePlaceholder(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? BrandColors.charcoal : BrandColors.stone,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 16,
            color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Handle link taps - special handling for audio files
  void _handleLinkTap(BuildContext context, String text, String? href, String? title, String basePath) async {
    if (href == null) return;

    // Check if it's an audio file
    final isAudio = href.endsWith('.opus') ||
        href.endsWith('.wav') ||
        href.endsWith('.mp3') ||
        href.endsWith('.m4a');

    if (isAudio) {
      final isRemoteUrl = href.startsWith('http://') || href.startsWith('https://');
      final audioPath = isRemoteUrl ? href : _resolveAssetPath(href, basePath);
      if (audioPath != null) {
        _showAudioPlayer(context, audioPath, text);
      }
      return;
    }

    // Handle web links
    if (href.startsWith('http://') || href.startsWith('https://')) {
      final uri = Uri.tryParse(href);
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('Failed to launch URL: $e');
        }
      }
      return;
    }

    // Handle mailto links
    if (href.startsWith('mailto:')) {
      final uri = Uri.tryParse(href);
      if (uri != null) {
        await launchUrl(uri);
      }
    }
  }

  /// Show a bottom sheet with the audio player
  void _showAudioPlayer(BuildContext context, String audioPath, String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            // Audio player placeholder — InlineAudioPlayer was in chat feature
            Text(
              'Audio: $title',
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
