import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/backend_health_provider.dart';
import 'package:parachute/core/services/performance_service.dart';
import '../models/chat_message.dart';
import 'inline_audio_player.dart';
import 'collapsible_thinking_section.dart';
import 'collapsible_compact_summary.dart';
import 'collapsible_code_block.dart';

/// Intent for copying message text
class CopyMessageIntent extends Intent {
  const CopyMessageIntent();
}

/// A chat message bubble with support for text, tool calls, and inline assets
class MessageBubble extends ConsumerWidget {
  final ChatMessage message;

  const MessageBubble({
    super.key,
    required this.message,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trace = perf.trace('MessageBubble.build', metadata: {
      'role': message.role.name,
      'contentLength': message.textContent.length,
      'isStreaming': message.isStreaming,
    });

    final isUser = message.role == MessageRole.user;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Get vault path for resolving relative asset paths
    final vaultPath = ref.watch(vaultPathProvider).valueOrNull;

    // Build the widget (synchronous part)
    final widget = _buildWidget(context, isUser, isDark, vaultPath);
    trace.end();
    return widget;
  }

  Widget _buildWidget(BuildContext context, bool isUser, bool isDark, String? vaultPath) {
    final messageBubble = Padding(
      padding: EdgeInsets.only(
        left: isUser ? 48 : 0,
        right: isUser ? 0 : 48,
        bottom: message.isCompactSummary ? 0 : Spacing.sm,
      ),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          decoration: BoxDecoration(
            color: isUser
                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                : (isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(Radii.lg),
              topRight: const Radius.circular(Radii.lg),
              bottomLeft: Radius.circular(isUser ? Radii.lg : Radii.sm),
              bottomRight: Radius.circular(isUser ? Radii.sm : Radii.lg),
            ),
          ),
          child: _MessageContentWithCopy(
            message: message,
            isUser: isUser,
            isDark: isDark,
            vaultPath: vaultPath,
            contentBuilder: () => _buildContent(context, isUser, isDark, vaultPath),
            getFullText: _getFullText,
            buildActionRow: () => _buildActionRow(context, isDark, isUser),
          ),
        ),
      ),
    );

    // Wrap compact summary messages in a collapsible container
    if (message.isCompactSummary) {
      // Get preview text (first ~50 chars of content)
      final preview = message.textContent.length > 50
          ? '${message.textContent.substring(0, 47)}...'
          : message.textContent;

      return CollapsibleCompactSummary(
        isDark: isDark,
        initiallyExpanded: false, // Collapsed by default
        previewText: preview.isNotEmpty ? preview : null,
        child: messageBubble,
      );
    }

    return messageBubble;
  }

  List<Widget> _buildContent(BuildContext context, bool isUser, bool isDark, String? vaultPath) {
    final widgets = <Widget>[];

    // Build content in order, grouping consecutive thinking/tool items together
    List<MessageContent> pendingThinkingItems = [];

    void flushThinkingItems() {
      if (pendingThinkingItems.isNotEmpty) {
        widgets.add(CollapsibleThinkingSection(
          items: List.from(pendingThinkingItems),
          isDark: isDark,
          // Expand during streaming so user can see work in progress
          initiallyExpanded: message.isStreaming,
        ));
        pendingThinkingItems = [];
      }
    }

    for (final content in message.content) {
      if (content.type == ContentType.text && content.text != null) {
        // Flush any pending thinking items before adding text
        flushThinkingItems();
        widgets.add(_buildTextContent(context, content.text!, isUser, isDark, vaultPath));
      } else if (content.type == ContentType.thinking || content.type == ContentType.toolUse) {
        // Accumulate thinking and tool calls
        pendingThinkingItems.add(content);
      }
    }

    // Flush any remaining thinking items
    flushThinkingItems();

    // Show streaming indicator if message is streaming and has no content yet
    if (message.isStreaming && widgets.isEmpty) {
      widgets.add(_buildStreamingIndicator(context, isDark));
    }

    return widgets;
  }

  Widget _buildTextContent(
      BuildContext context, String text, bool isUser, bool isDark, String? vaultPath) {
    final textColor = isUser
        ? Colors.white
        : (isDark ? BrandColors.nightText : BrandColors.charcoal);

    // Use markdown for both user and assistant messages to support formatting
    // Note: selectable: false because we use SelectionArea wrapper for proper
    // multi-line selection across the entire message bubble
    return Padding(
      padding: Spacing.cardPadding,
      child: _SafeMarkdownBody(
        text: text,
        textColor: textColor,
        isUser: isUser,
        isDark: isDark,
        vaultPath: vaultPath,
        onImageBuild: _buildImage,
        onLinkTap: (linkText, href, title) =>
            _handleLinkTap(context, linkText, href, title, vaultPath),
      ),
    );
  }

  /// Get all text content from the message for copying
  String _getFullText() {
    final textParts = <String>[];
    for (final content in message.content) {
      if (content.type == ContentType.text && content.text != null) {
        textParts.add(content.text!);
      }
    }
    return textParts.join('\n');
  }

  /// Build action row with copy button
  Widget _buildActionRow(BuildContext context, bool isDark, bool isUser) {
    return Padding(
      padding: const EdgeInsets.only(
        left: Spacing.sm,
        right: Spacing.sm,
        bottom: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CopyButton(
            text: _getFullText(),
            isDark: isDark,
            isUser: isUser,
          ),
        ],
      ),
    );
  }

  /// Resolve a relative asset path to an absolute path
  String? _resolveAssetPath(String path, String? vaultPath) {
    if (vaultPath == null) return null;

    // Already absolute
    if (path.startsWith('/')) return path;

    // Remove leading ./ if present
    final cleanPath = path.startsWith('./') ? path.substring(2) : path;

    return '$vaultPath/$cleanPath';
  }

  /// Build an inline image widget
  Widget _buildImage(Uri uri, String? title, String? alt, String? vaultPath, bool isDark) {
    final uriString = uri.toString();

    // Check if it's a remote URL (http or https)
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return _buildRemoteImage(uriString, alt, isDark);
    }

    // Handle local file paths
    final path = _resolveAssetPath(uriString, vaultPath);

    if (path == null) {
      return _buildImagePlaceholder(alt ?? 'Image', isDark);
    }

    // Try to find the file, including with alternate extensions
    // (nano-banana may save .jpeg when .png was requested)
    return FutureBuilder<File?>(
      future: _findImageFile(path),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return _buildImagePlaceholder(alt ?? uri.toString(), isDark);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          child: GestureDetector(
            onTap: () => _showImagePreview(context, file, isDark),
            onSecondaryTapUp: (details) => _showImageContextMenu(
              context, details.globalPosition, file, isDark,
            ),
            onLongPressStart: (details) => _showImageContextMenu(
              context, details.globalPosition, file, isDark,
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Image.file(
                  file,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) =>
                      _buildImagePlaceholder('Failed to load image', isDark),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Build a remote image widget from URL
  Widget _buildRemoteImage(String url, String? alt, bool isDark) {
    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: GestureDetector(
          onTap: () => _showRemoteImagePreview(context, url, isDark),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Image.network(
                url,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Container(
                    padding: const EdgeInsets.all(Spacing.lg),
                    decoration: BoxDecoration(
                      color: isDark ? BrandColors.nightSurface : BrandColors.cream,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!
                              : null,
                          strokeWidth: 2,
                          color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                        ),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          'Loading image...',
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  );
                },
                errorBuilder: (context, error, stack) =>
                    _buildImagePlaceholder(alt ?? 'Failed to load remote image', isDark),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Show fullscreen preview for remote image with download option
  void _showRemoteImagePreview(BuildContext context, String url, bool isDark) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black87,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _RemoteImagePreviewOverlay(
            url: url,
            isDark: isDark,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }

  /// Show fullscreen image preview with download option
  void _showImagePreview(BuildContext context, File file, bool isDark) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black87,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _ImagePreviewOverlay(
            file: file,
            isDark: isDark,
            onSave: () => _saveImageAs(context, file),
            onReveal: () => _revealInFinder(file),
            onCopy: () => _copyImageToClipboard(context, file),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }

  /// Show context menu for image with copy/save options
  void _showImageContextMenu(
    BuildContext context,
    Offset position,
    File file,
    bool isDark,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy, size: 18, color: isDark ? BrandColors.nightText : BrandColors.charcoal),
              const SizedBox(width: Spacing.sm),
              const Text('Copy image'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'save',
          child: Row(
            children: [
              Icon(Icons.save_alt, size: 18, color: isDark ? BrandColors.nightText : BrandColors.charcoal),
              const SizedBox(width: Spacing.sm),
              const Text('Save image as...'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'reveal',
          child: Row(
            children: [
              Icon(Icons.folder_open, size: 18, color: isDark ? BrandColors.nightText : BrandColors.charcoal),
              const SizedBox(width: Spacing.sm),
              const Text('Show in folder'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'copy':
          _copyImageToClipboard(context, file);
          break;
        case 'save':
          _saveImageAs(context, file);
          break;
        case 'reveal':
          _revealInFinder(file);
          break;
      }
    });
  }

  /// Copy image path to clipboard
  Future<void> _copyImageToClipboard(BuildContext context, File file) async {
    try {
      // Copy file path to clipboard
      // Note: Full image clipboard support requires platform-specific implementation
      await Clipboard.setData(ClipboardData(text: file.path));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Image path copied to clipboard'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to copy: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Save image to a new location
  Future<void> _saveImageAs(BuildContext context, File file) async {
    try {
      final fileName = file.path.split('/').last;
      final extension = fileName.split('.').last;

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save image as',
        fileName: fileName,
        type: FileType.image,
        allowedExtensions: [extension],
      );

      if (result != null) {
        await file.copy(result);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image saved to ${result.split('/').last}'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Reveal file in Finder/Explorer
  Future<void> _revealInFinder(File file) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', file.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', file.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [file.parent.path]);
      }
    } catch (e) {
      debugPrint('Failed to reveal file: $e');
    }
  }

  /// Find an image file, trying alternate extensions if needed
  Future<File?> _findImageFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      return file;
    }

    // Try alternate extensions (handles .png -> .jpeg mismatch)
    final alternateExtensions = ['.jpeg', '.jpg', '.png', '.webp'];
    final basePath = path.replaceAll(RegExp(r'\.[^.]+$'), '');

    for (final ext in alternateExtensions) {
      final altFile = File('$basePath$ext');
      if (await altFile.exists()) {
        return altFile;
      }
    }

    return null;
  }

  Widget _buildImagePlaceholder(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 16,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Handle link taps - special handling for audio files and web links
  void _handleLinkTap(BuildContext context, String text, String? href, String? title, String? vaultPath) async {
    if (href == null) return;

    // Check if it's an audio file
    final isAudio = href.endsWith('.opus') ||
        href.endsWith('.wav') ||
        href.endsWith('.mp3') ||
        href.endsWith('.m4a');

    if (isAudio) {
      // For remote URLs, use href directly; for local files, resolve the path
      final isRemoteUrl = href.startsWith('http://') || href.startsWith('https://');
      final audioPath = isRemoteUrl ? href : _resolveAssetPath(href, vaultPath);
      if (audioPath != null) {
        _showAudioPlayer(context, audioPath, text);
      }
      return;
    }

    // Handle web links (http/https)
    if (href.startsWith('http://') || href.startsWith('https://')) {
      final uri = Uri.tryParse(href);
      if (uri != null) {
        try {
          final launched = await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          if (!launched && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not open link: $href'),
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error opening link: $e'),
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
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
      return;
    }

    // Handle local file links - try to open in Finder/Explorer
    final resolvedPath = _resolveAssetPath(href, vaultPath);
    if (resolvedPath != null) {
      final file = File(resolvedPath);
      if (await file.exists()) {
        _revealInFinder(file);
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            InlineAudioPlayer(
              audioPath: audioPath,
              title: title,
            ),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      ),
    );
  }


  Widget _buildStreamingIndicator(BuildContext context, bool isDark) {
    return Padding(
      padding: Spacing.cardPadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
          const SizedBox(width: 4),
          _PulsingDot(
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            delay: const Duration(milliseconds: 150),
          ),
          const SizedBox(width: 4),
          _PulsingDot(
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            delay: const Duration(milliseconds: 300),
          ),
        ],
      ),
    );
  }

}

/// Animated pulsing dot for streaming indicator
class _PulsingDot extends StatefulWidget {
  final Color color;
  final Duration delay;

  const _PulsingDot({
    required this.color,
    this.delay = Duration.zero,
  });

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    Future.delayed(widget.delay, () {
      if (mounted) {
        _controller.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

/// Message content wrapper with keyboard shortcuts and context menu for copying
class _MessageContentWithCopy extends StatefulWidget {
  final ChatMessage message;
  final bool isUser;
  final bool isDark;
  final String? vaultPath;
  final List<Widget> Function() contentBuilder;
  final String Function() getFullText;
  final Widget Function() buildActionRow;

  const _MessageContentWithCopy({
    required this.message,
    required this.isUser,
    required this.isDark,
    required this.vaultPath,
    required this.contentBuilder,
    required this.getFullText,
    required this.buildActionRow,
  });

  @override
  State<_MessageContentWithCopy> createState() => _MessageContentWithCopyState();
}

class _MessageContentWithCopyState extends State<_MessageContentWithCopy> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _copyToClipboard() {
    final text = widget.getFullText();
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message copied to clipboard'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final text = widget.getFullText();
    if (text.isEmpty) return;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(
                Icons.copy,
                size: 18,
                color: widget.isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              const SizedBox(width: Spacing.sm),
              const Text('Copy message'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        _copyToClipboard();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.getFullText();

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Cmd+C / Ctrl+C to copy
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyC): const CopyMessageIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyC): const CopyMessageIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          CopyMessageIntent: CallbackAction<CopyMessageIntent>(
            onInvoke: (_) {
              _copyToClipboard();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
          onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
          child: Focus(
            focusNode: _focusNode,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Message content with selection support
                SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.contentBuilder(),
                  ),
                ),
                // Copy button row
                if (text.isNotEmpty)
                  widget.buildActionRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Copy button with visual feedback
class _CopyButton extends StatefulWidget {
  final String text;
  final bool isDark;
  final bool isUser;

  const _CopyButton({
    required this.text,
    required this.isDark,
    required this.isUser,
  });

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() => _copied = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.isUser
        ? Colors.white.withValues(alpha: 0.7)
        : (widget.isDark
            ? BrandColors.nightTextSecondary
            : BrandColors.driftwood);

    return GestureDetector(
      onTap: _copyToClipboard,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs,
          vertical: Spacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check : Icons.copy,
              size: 14,
              color: _copied
                  ? (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                  : iconColor,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: _copied
                    ? (widget.isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                    : iconColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen image preview overlay with download and actions
class _ImagePreviewOverlay extends StatelessWidget {
  final File file;
  final bool isDark;
  final VoidCallback onSave;
  final VoidCallback onReveal;
  final VoidCallback onCopy;

  const _ImagePreviewOverlay({
    required this.file,
    required this.isDark,
    required this.onSave,
    required this.onReveal,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = file.path.split('/').last;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            // Image centered
            Center(
              child: GestureDetector(
                onTap: () {}, // Prevent closing when tapping image
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            // Top bar with filename and close
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + Spacing.sm,
                  left: Spacing.md,
                  right: Spacing.md,
                  bottom: Spacing.sm,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        fileName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: TypographyTokens.bodyMedium,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
            ),
            // Bottom action bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + Spacing.md,
                  top: Spacing.md,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ActionButton(
                      icon: Icons.save_alt,
                      label: 'Download',
                      onTap: () {
                        Navigator.of(context).pop();
                        onSave();
                      },
                    ),
                    const SizedBox(width: Spacing.xl),
                    _ActionButton(
                      icon: Icons.copy,
                      label: 'Copy Path',
                      onTap: () {
                        Navigator.of(context).pop();
                        onCopy();
                      },
                    ),
                    const SizedBox(width: Spacing.xl),
                    _ActionButton(
                      icon: Icons.folder_open,
                      label: 'Show in Folder',
                      onTap: () {
                        Navigator.of(context).pop();
                        onReveal();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Action button for image preview overlay
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: TypographyTokens.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fullscreen remote image preview overlay with download option
class _RemoteImagePreviewOverlay extends StatefulWidget {
  final String url;
  final bool isDark;

  const _RemoteImagePreviewOverlay({
    required this.url,
    required this.isDark,
  });

  @override
  State<_RemoteImagePreviewOverlay> createState() => _RemoteImagePreviewOverlayState();
}

class _RemoteImagePreviewOverlayState extends State<_RemoteImagePreviewOverlay> {
  bool _isDownloading = false;

  String get _fileName {
    final uri = Uri.tryParse(widget.url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return 'image';
  }

  Future<void> _downloadImage() async {
    setState(() => _isDownloading = true);

    try {
      // Get file extension from URL or default to .png
      var fileName = _fileName;
      if (!fileName.contains('.')) {
        fileName = '$fileName.png';
      }

      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save image as',
        fileName: fileName,
        type: FileType.image,
      );

      if (result != null) {
        // Download the image
        final httpClient = HttpClient();
        final request = await httpClient.getUrl(Uri.parse(widget.url));
        final response = await request.close();
        final bytes = await consolidateHttpClientResponseBytes(response);

        // Write to file
        final file = File(result);
        await file.writeAsBytes(bytes);

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image saved to ${result.split('/').last}'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to download: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Future<void> _copyUrlToClipboard() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image URL copied to clipboard'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            // Image centered
            Center(
              child: GestureDetector(
                onTap: () {}, // Prevent closing when tapping image
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: Image.network(
                    widget.url,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!
                              : null,
                          color: Colors.white,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stack) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 48),
                        const SizedBox(height: Spacing.sm),
                        const Text(
                          'Failed to load image',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Top bar with filename and close
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + Spacing.sm,
                  left: Spacing.md,
                  right: Spacing.md,
                  bottom: Spacing.sm,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _fileName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: TypographyTokens.bodyMedium,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
            ),
            // Bottom action bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + Spacing.md,
                  top: Spacing.md,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ActionButton(
                      icon: _isDownloading ? Icons.hourglass_empty : Icons.save_alt,
                      label: _isDownloading ? 'Saving...' : 'Download',
                      onTap: _isDownloading ? () {} : _downloadImage,
                    ),
                    const SizedBox(width: Spacing.xl),
                    _ActionButton(
                      icon: Icons.copy,
                      label: 'Copy URL',
                      onTap: _copyUrlToClipboard,
                    ),
                    const SizedBox(width: Spacing.xl),
                    _ActionButton(
                      icon: Icons.open_in_browser,
                      label: 'Open in Browser',
                      onTap: _openInBrowser,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Safe markdown renderer that handles edge cases
/// flutter_markdown can throw assertion errors on certain edge cases
/// (unclosed inline elements, streaming partial content, etc.)
/// This widget pre-parses markdown and falls back to plain text if needed.
class _SafeMarkdownBody extends StatelessWidget {
  final String text;
  final Color textColor;
  final bool isUser;
  final bool isDark;
  final String? vaultPath;
  final Widget Function(Uri, String?, String?, String?, bool) onImageBuild;
  final void Function(String, String?, String?) onLinkTap;

  const _SafeMarkdownBody({
    required this.text,
    required this.textColor,
    required this.isUser,
    required this.isDark,
    required this.vaultPath,
    required this.onImageBuild,
    required this.onLinkTap,
  });

  /// Check if markdown content can be safely parsed
  /// Returns true if the markdown is safe to render, false if we should fall back to plain text
  static bool _canSafelyParse(String input) {
    try {
      // Try parsing with the markdown package
      final document = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
      final nodes = document.parseLines(input.split('\n'));

      // Check for patterns that cause the _inlines.isEmpty assertion
      // This happens when inline elements are not properly closed
      if (!_checkNodesForProblems(nodes)) {
        return false;
      }

      // Additional heuristic checks for patterns known to crash flutter_markdown
      // These patterns can parse fine but still cause builder issues
      if (_hasProblematicPatterns(input)) {
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[_SafeMarkdownBody] Parse error: $e');
      return false;
    }
  }

  /// Check for patterns that are known to cause flutter_markdown builder failures
  /// even when the markdown parses correctly
  ///
  /// NOTE: Be conservative here - only block patterns that ACTUALLY crash,
  /// not patterns that might look weird but render fine.
  static bool _hasProblematicPatterns(String input) {
    // Pattern 1: XML-like tags with colons that cause _inlines.isEmpty assertion
    // e.g., <function_calls> - these specific patterns crash the builder
    final xmlTagsWithColon = RegExp(r'<[a-zA-Z]+:[a-zA-Z_]+[^>]*>');
    if (xmlTagsWithColon.hasMatch(input)) {
      final match = xmlTagsWithColon.firstMatch(input)!;
      if (!_isInCodeBlock(input, match.start)) {
        debugPrint('[_SafeMarkdownBody] Blocked by pattern 1 (XML colon tags): ${match.group(0)}');
        return true;
      }
    }

    // Pattern 2: Any angle-bracket tags that look like XML/HTML but aren't standard HTML
    // flutter_markdown struggles with these when they're not in code blocks
    // e.g., <function_calls>, <example>, <user>, <assistant>, etc.
    final customTags = RegExp(r'</?[a-zA-Z][a-zA-Z0-9_-]*(?:\s[^>]*)?>');
    for (final match in customTags.allMatches(input)) {
      final tag = match.group(0)!.toLowerCase();
      // Allow standard HTML tags that flutter_markdown handles
      final standardHtmlTags = {
        '<br>', '<br/>', '<br />', '<hr>', '<hr/>', '<hr />',
        '<b>', '</b>', '<i>', '</i>', '<u>', '</u>',
        '<strong>', '</strong>', '<em>', '</em>',
        '<code>', '</code>', '<pre>', '</pre>',
        '<p>', '</p>', '<div>', '</div>', '<span>', '</span>',
        '<a', '</a>', '<img', '<h1>', '</h1>', '<h2>', '</h2>',
        '<h3>', '</h3>', '<h4>', '</h4>', '<h5>', '</h5>', '<h6>', '</h6>',
        '<ul>', '</ul>', '<ol>', '</ol>', '<li>', '</li>',
        '<table>', '</table>', '<tr>', '</tr>', '<td>', '</td>', '<th>', '</th>',
        '<thead>', '</thead>', '<tbody>', '</tbody>',
        '<blockquote>', '</blockquote>', '<sup>', '</sup>', '<sub>', '</sub>',
      };

      // Check if it's a standard tag (need to check prefix for tags with attributes)
      final isStandard = standardHtmlTags.any((std) =>
        tag == std || tag.startsWith(std.replaceAll('>', ' ')) || tag.startsWith(std.replaceAll('>', '>'))
      );

      if (!isStandard && !_isInCodeBlock(input, match.start)) {
        debugPrint('[_SafeMarkdownBody] Blocked by pattern 2 (custom XML tag): ${match.group(0)}');
        return true;
      }
    }

    // Pattern 3: Unclosed image syntax ![ at end of string (streaming)
    final unclosedImage = RegExp(r'!\[[^\]]*$');
    if (unclosedImage.hasMatch(input)) {
      debugPrint('[_SafeMarkdownBody] Blocked by pattern 3 (unclosed image)');
      return true;
    }

    // Pattern 4: Unclosed emphasis at end (streaming) - only trailing unclosed
    // e.g., "text **bold" or "text *italic" at the very end
    final trailingUnclosedEmphasis = RegExp(r'(?<!\*)\*{1,2}[^*\n]+$');
    if (trailingUnclosedEmphasis.hasMatch(input)) {
      // Only flag if it's actually unclosed (odd number of markers)
      final match = trailingUnclosedEmphasis.firstMatch(input)!;
      final markerCount = match.group(0)!.startsWith('**') ? 2 : 1;
      final textAfter = input.substring(match.start);
      final closingMarkers = markerCount == 2
          ? RegExp(r'\*\*').allMatches(textAfter).length
          : RegExp(r'(?<!\*)\*(?!\*)').allMatches(textAfter).length;
      if (closingMarkers % 2 != 0) {
        debugPrint('[_SafeMarkdownBody] Blocked by pattern 4 (trailing unclosed emphasis)');
        return true;
      }
    }

    // Pattern 5: Nested brackets that can confuse the parser
    // e.g., [[text]] or [text [nested] more]
    final nestedBrackets = RegExp(r'\[[^\]]*\[[^\]]*\]');
    if (nestedBrackets.hasMatch(input)) {
      final match = nestedBrackets.firstMatch(input)!;
      if (!_isInCodeBlock(input, match.start)) {
        debugPrint('[_SafeMarkdownBody] Blocked by pattern 5 (nested brackets): ${match.group(0)}');
        return true;
      }
    }

    return false;
  }

  /// Check if a position in the text is inside a code block or inline code
  static bool _isInCodeBlock(String text, int position) {
    // Check for fenced code blocks
    final beforePosition = text.substring(0, position);
    final codeFenceCount = RegExp(r'^```', multiLine: true).allMatches(beforePosition).length;
    if (codeFenceCount % 2 == 1) {
      return true; // Inside a fenced code block
    }

    // Check for inline code on the same line
    final lineStart = beforePosition.lastIndexOf('\n') + 1;
    final lineBeforePosition = beforePosition.substring(lineStart);
    final backtickCount = '`'.allMatches(lineBeforePosition).length;
    if (backtickCount % 2 == 1) {
      return true; // Inside inline code
    }

    return false;
  }

  /// Recursively check AST nodes for problematic patterns
  static bool _checkNodesForProblems(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is md.Element) {
        // Check children recursively
        if (!_checkNodesForProblems(node.children ?? [])) {
          return false;
        }
      }
    }
    return true;
  }

  /// Sanitize markdown to fix common issues that cause parser failures
  static String _sanitizeMarkdown(String input) {
    var result = input;

    // Handle unclosed code fences (```) - common during streaming
    final codeFencePattern = RegExp(r'^```', multiLine: true);
    final codeFenceCount = codeFencePattern.allMatches(result).length;
    if (codeFenceCount % 2 != 0) {
      result = '$result\n```';
    }

    // Handle trailing unclosed inline code
    // Count backticks outside of code fences
    final lines = result.split('\n');
    var inCodeFence = false;
    var backtickCount = 0;

    for (final line in lines) {
      if (line.startsWith('```')) {
        inCodeFence = !inCodeFence;
        continue;
      }
      if (!inCodeFence) {
        // Count backticks in this line
        backtickCount += '`'.allMatches(line).length;
      }
    }

    // If odd number of backticks, add one to close
    if (backtickCount % 2 != 0) {
      result = '$result`';
    }

    // Handle unclosed links [text](url - common during streaming
    final unclosedLinkPattern = RegExp(r'\[[^\]]*\]\([^)]*$');
    if (unclosedLinkPattern.hasMatch(result)) {
      result = '$result)';
    }

    // Handle unclosed brackets at end
    if (result.endsWith('[')) {
      result = '${result.substring(0, result.length - 1)}\\[';
    }

    return result;
  }

  Widget _buildPlainText() {
    return Text(
      text,
      style: TextStyle(
        color: textColor,
        fontSize: TypographyTokens.bodyMedium,
        height: TypographyTokens.lineHeightNormal,
      ),
    );
  }

  Widget _buildMarkdown(String content) {
    return MarkdownBody(
      data: content,
      selectable: false,
      builders: {
        'pre': CollapsibleCodeBlockBuilder(isDark: isDark),
      },
      // ignore: deprecated_member_use
      imageBuilder: (uri, title, alt) =>
          onImageBuild(uri, title, alt, vaultPath, isDark),
      onTapLink: onLinkTap,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.bodyMedium,
          height: TypographyTokens.lineHeightNormal,
        ),
        a: TextStyle(
          color: isUser
              ? Colors.white
              : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
          decoration: TextDecoration.underline,
          decorationColor: isUser
              ? Colors.white.withValues(alpha: 0.7)
              : (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
        ),
        code: TextStyle(
          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          backgroundColor: isDark
              ? BrandColors.nightSurface
              : BrandColors.cream,
          fontFamily: 'monospace',
          fontSize: TypographyTokens.bodySmall,
        ),
        codeblockDecoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurface : BrandColors.cream,
          borderRadius: Radii.badge,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isDark
                  ? BrandColors.nightForest
                  : BrandColors.forest,
              width: 3,
            ),
          ),
        ),
        h1: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineLarge,
          fontWeight: FontWeight.bold,
        ),
        h2: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineMedium,
          fontWeight: FontWeight.bold,
        ),
        h3: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineSmall,
          fontWeight: FontWeight.bold,
        ),
        listBullet: TextStyle(color: textColor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // First sanitize the markdown (close unclosed fences, etc.)
    final sanitizedText = _sanitizeMarkdown(text);

    // Pre-check for problematic patterns before attempting to render
    // This catches patterns that cause flutter_markdown assertion errors
    final isSafe = _canSafelyParse(sanitizedText);
    debugPrint('[_SafeMarkdownBody] Checking ${text.length} chars, safe=$isSafe');
    if (!isSafe) {
      debugPrint('[_SafeMarkdownBody] Falling back to plain text due to unsafe patterns');
      debugPrint('[_SafeMarkdownBody] First 200 chars: ${text.substring(0, text.length > 200 ? 200 : text.length)}');
      return _buildPlainText();
    }

    // Try to render markdown, fall back to plain text only on actual errors
    // We use an ErrorWidget.builder approach via a custom error boundary
    return _MarkdownErrorBoundary(
      markdown: sanitizedText,
      markdownBuilder: () => _buildMarkdown(sanitizedText),
      fallbackBuilder: () => _buildPlainText(),
    );
  }
}

/// Error boundary that catches flutter_markdown rendering errors
/// and falls back to plain text.
///
/// This uses a custom ErrorWidget.builder to catch Flutter assertion errors
/// that propagate through the framework rather than as exceptions.
class _MarkdownErrorBoundary extends StatefulWidget {
  final String markdown;
  final Widget Function() markdownBuilder;
  final Widget Function() fallbackBuilder;

  const _MarkdownErrorBoundary({
    required this.markdown,
    required this.markdownBuilder,
    required this.fallbackBuilder,
  });

  @override
  State<_MarkdownErrorBoundary> createState() => _MarkdownErrorBoundaryState();
}

class _MarkdownErrorBoundaryState extends State<_MarkdownErrorBoundary> {
  bool _hasError = false;
  Widget? _cachedWidget;
  String? _cachedMarkdown;

  @override
  void didUpdateWidget(_MarkdownErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset error state and cache when markdown content changes
    if (oldWidget.markdown != widget.markdown) {
      _hasError = false;
      _cachedWidget = null;
      _cachedMarkdown = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return widget.fallbackBuilder();
    }

    // Return cached widget if markdown hasn't changed
    if (_cachedMarkdown == widget.markdown && _cachedWidget != null) {
      return _cachedWidget!;
    }

    // Build markdown with error catching
    try {
      final markdownWidget = widget.markdownBuilder();
      _cachedWidget = markdownWidget;
      _cachedMarkdown = widget.markdown;
      return markdownWidget;
    } catch (e, stackTrace) {
      debugPrint('[_MarkdownErrorBoundary] Markdown render error: $e');
      debugPrint('[_MarkdownErrorBoundary] Stack: $stackTrace');
      // Schedule state update for next frame to avoid setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasError) {
          setState(() => _hasError = true);
        }
      });
      return widget.fallbackBuilder();
    }
  }
}
