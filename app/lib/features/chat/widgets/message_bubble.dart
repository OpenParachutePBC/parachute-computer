import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_message.dart';
import 'inline_audio_player.dart';
import 'collapsible_thinking_section.dart';
import 'collapsible_compact_summary.dart';
// NOTE: CollapsibleCodeBlockBuilder removed due to flutter_markdown bug
// import 'collapsible_code_block.dart';

/// A chat message bubble with support for text, tool calls, and inline assets
///
/// Uses AutomaticKeepAliveClientMixin to prevent expensive rebuilds when
/// scrolling. This is critical for scroll performance with markdown content.
class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final String? vaultPath;

  const MessageBubble({
    super.key,
    required this.message,
    this.vaultPath,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Must call super.build for AutomaticKeepAliveClientMixin to work
    super.build(context);

    final isUser = widget.message.role == MessageRole.user;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Wrap in RepaintBoundary to isolate paint operations during scroll
    return RepaintBoundary(
      child: _buildWidget(context, isUser, isDark, widget.vaultPath),
    );
  }

  Widget _buildWidget(BuildContext context, bool isUser, bool isDark, String? vaultPath) {
    // Use LayoutBuilder instead of MediaQuery to avoid rebuild on keyboard/orientation
    // and cache the constraints at the message level
    final messageBubble = Padding(
      padding: EdgeInsets.only(
        left: isUser ? 48 : 0,
        right: isUser ? 0 : 48,
        bottom: widget.message.isCompactSummary ? 0 : Spacing.sm,
      ),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) => Container(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth * 0.85,
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
            message: widget.message,
            isUser: isUser,
            isDark: isDark,
            vaultPath: vaultPath,
            contentBuilder: () => _buildContent(context, isUser, isDark, vaultPath),
            getFullText: _getFullText,
            buildActionRow: () => _buildActionRow(context, isDark, isUser),
          ),
        )),
      ),
    );

    // Wrap compact summary messages in a collapsible container
    if (widget.message.isCompactSummary) {
      // Get preview text (first ~50 chars of content)
      final preview = widget.message.textContent.length > 50
          ? '${widget.message.textContent.substring(0, 47)}...'
          : widget.message.textContent;

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
          initiallyExpanded: widget.message.isStreaming,
        ));
        pendingThinkingItems = [];
      }
    }

    for (final content in widget.message.content) {
      if (content.type == ContentType.text && content.text != null) {
        // Flush any pending thinking items before adding text
        flushThinkingItems();
        widgets.add(_buildTextContent(context, content.text!, isUser, isDark, vaultPath));
      } else if (content.type == ContentType.warning && content.text != null) {
        // Flush any pending thinking items before adding warning
        flushThinkingItems();
        widgets.add(_buildWarningContent(context, content.text!, isDark));
      } else if (content.type == ContentType.thinking || content.type == ContentType.toolUse) {
        // Accumulate thinking and tool calls
        pendingThinkingItems.add(content);
      }
    }

    // Flush any remaining thinking items
    flushThinkingItems();

    // Show streaming indicator if message is streaming and has no content yet
    if (widget.message.isStreaming && widgets.isEmpty) {
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

  Widget _buildWarningContent(BuildContext context, String text, bool isDark) {
    return Padding(
      padding: Spacing.cardPadding,
      child: Container(
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: (isDark ? Colors.orange.shade900 : Colors.orange.shade50)
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Spacing.xs),
          border: Border(
            left: BorderSide(
              color: isDark ? Colors.orange.shade700 : Colors.orange.shade300,
              width: 3,
            ),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.orange.shade200 : Colors.orange.shade900,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  /// Get all text content from the message for copying
  String _getFullText() {
    final textParts = <String>[];
    for (final content in widget.message.content) {
      if ((content.type == ContentType.text ||
              content.type == ContentType.warning) &&
          content.text != null) {
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

  /// Cache for resolved image file paths to avoid repeated filesystem checks
  static final Map<String, File?> _imageFileCache = {};

  /// Find an image file, trying alternate extensions if needed
  Future<File?> _findImageFile(String path) async {
    // Return cached result if available
    if (_imageFileCache.containsKey(path)) {
      return _imageFileCache[path];
    }

    final file = File(path);
    if (await file.exists()) {
      _imageFileCache[path] = file;
      return file;
    }

    // Try alternate extensions (handles .png -> .jpeg mismatch)
    final alternateExtensions = ['.jpeg', '.jpg', '.png', '.webp'];
    final basePath = path.replaceAll(RegExp(r'\.[^.]+$'), '');

    for (final ext in alternateExtensions) {
      final altFile = File('$basePath$ext');
      if (await altFile.exists()) {
        _imageFileCache[path] = altFile;
        return altFile;
      }
    }

    _imageFileCache[path] = null;
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
    // Use a simple, efficient streaming indicator instead of multiple animated dots
    // This reduces animation overhead from 3 controllers to 1 built-in widget
    return Padding(
      padding: Spacing.cardPadding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Thinking...',
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              fontSize: TypographyTokens.labelSmall,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
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
        Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Message copied to clipboard'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.getFullText();

    return GestureDetector(
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Message content
          ...widget.contentBuilder(),
          // Copy button row
          if (text.isNotEmpty)
            widget.buildActionRow(),
        ],
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
        try {
          final request = await httpClient.getUrl(Uri.parse(widget.url));
          final response = await request.close();
          final bytes = await consolidateHttpClientResponseBytes(response);

          // Write to file
          final file = File(result);
          await file.writeAsBytes(bytes);
        } finally {
          httpClient.close();
        }

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
/// This widget catches errors and falls back to plain text.
class _SafeMarkdownBody extends StatefulWidget {
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

  @override
  State<_SafeMarkdownBody> createState() => _SafeMarkdownBodyState();
}

/// Global cache of markdown content hashes that have caused render failures
final Set<int> _failedMarkdownHashes = {};

/// Callbacks to notify widgets when their content fails (for triggering rebuild)
final Map<int, VoidCallback> _failureCallbacks = {};

/// Track currently rendering markdown for global error handler attribution
String? currentlyRenderingMarkdown;

/// Mark a markdown hash as failed (called from global error handler)
void markMarkdownAsFailed(int hash) {
  _failedMarkdownHashes.add(hash);
  // Notify the widget if it registered a callback
  _failureCallbacks[hash]?.call();
  _failureCallbacks.remove(hash);
}

/// Cache for MarkdownStyleSheet to avoid rebuilding on every frame
/// Key is combination of isDark, isUser, and textColor
/// Evicts when cache exceeds 50 entries to prevent unbounded growth
final Map<int, MarkdownStyleSheet> _styleSheetCache = {};
const int _maxStyleSheetCacheSize = 50;

MarkdownStyleSheet _getOrCreateStyleSheet({
  required bool isDark,
  required bool isUser,
  required Color textColor,
}) {
  // Create a cache key from the parameters
  final key = Object.hash(isDark, isUser, textColor.toARGB32());

  // Evict cache if it grows too large
  if (_styleSheetCache.length >= _maxStyleSheetCacheSize && !_styleSheetCache.containsKey(key)) {
    _styleSheetCache.clear();
  }

  return _styleSheetCache.putIfAbsent(key, () => MarkdownStyleSheet(
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
  ));
}

class _SafeMarkdownBodyState extends State<_SafeMarkdownBody> {
  bool _hasError = false;
  Widget? _cachedMarkdown;
  int? _cachedHash;

  @override
  void initState() {
    super.initState();
    _hasError = _failedMarkdownHashes.contains(widget.text.hashCode);
    _registerCallback();
  }

  @override
  void didUpdateWidget(_SafeMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _unregisterCallback(oldWidget.text.hashCode);
      _hasError = _failedMarkdownHashes.contains(widget.text.hashCode);
      _registerCallback();
    }
  }

  @override
  void dispose() {
    _unregisterCallback(widget.text.hashCode);
    super.dispose();
  }

  void _registerCallback() {
    if (!_hasError) {
      _failureCallbacks[widget.text.hashCode] = _onError;
    }
  }

  void _unregisterCallback(int hash) {
    _failureCallbacks.remove(hash);
  }

  void _onError() {
    if (mounted && !_hasError) {
      setState(() => _hasError = true);
    }
  }

  /// Sanitize markdown for streaming (close unclosed fences) — single pass
  String _sanitizeForStreaming(String input) {
    var codeFenceCount = 0;
    var inCodeFence = false;
    var backtickCount = 0;
    var hasUnclosedLink = false;

    // Single pass: scan lines for fences, backticks, and link state
    final lines = input.split('\n');
    for (final line in lines) {
      if (line.startsWith('```')) {
        codeFenceCount++;
        inCodeFence = !inCodeFence;
        continue;
      }
      if (!inCodeFence) {
        for (var i = 0; i < line.length; i++) {
          if (line.codeUnitAt(i) == 0x60) backtickCount++; // '`'
        }
      }
    }

    // Check last line for unclosed link pattern [text](url...
    if (lines.isNotEmpty) {
      final lastLine = lines.last;
      var bracketOpen = false;
      var parenOpen = false;
      for (var i = 0; i < lastLine.length; i++) {
        final c = lastLine.codeUnitAt(i);
        if (c == 0x5B) { bracketOpen = true; parenOpen = false; } // '['
        else if (c == 0x5D && bracketOpen) { bracketOpen = false; } // ']'
        else if (c == 0x28 && i > 0 && lastLine.codeUnitAt(i - 1) == 0x5D) { parenOpen = true; } // '('
        else if (c == 0x29 && parenOpen) { parenOpen = false; } // ')'
      }
      hasUnclosedLink = parenOpen;
    }

    // Build result only if fixes are needed
    if (codeFenceCount % 2 == 0 && backtickCount % 2 == 0 && !hasUnclosedLink) {
      return input;
    }

    var result = input;
    if (codeFenceCount % 2 != 0) result = '$result\n```';
    if (backtickCount % 2 != 0) result = '$result`';
    if (hasUnclosedLink) result = '$result)';
    return result;
  }

  Widget _buildPlainText() {
    return Text(
      widget.text,
      style: TextStyle(
        color: widget.textColor,
        fontSize: TypographyTokens.bodyMedium,
        height: TypographyTokens.lineHeightNormal,
      ),
    );
  }

  Widget _buildMarkdown(String content) {
    // Use cached stylesheet to avoid recreating TextStyle objects on every build
    final styleSheet = _getOrCreateStyleSheet(
      isDark: widget.isDark,
      isUser: widget.isUser,
      textColor: widget.textColor,
    );

    return MarkdownBody(
      // Use a key based on content to prevent rebuilds with stale builder state
      key: ValueKey(content.hashCode),
      data: content,
      selectable: false,
      // NOTE: Custom builders removed due to flutter_markdown bug.
      // Using custom builders causes '_inlines.isEmpty' assertion errors
      // when navigating away from screens (the library doesn't properly
      // reset internal state during didChangeDependencies).
      // Code blocks will render with default styling until this is fixed upstream.
      // See: https://github.com/flutter/flutter/issues/
      // ignore: deprecated_member_use
      imageBuilder: (uri, title, alt) =>
          widget.onImageBuild(uri, title, alt, widget.vaultPath, widget.isDark),
      onTapLink: widget.onLinkTap,
      styleSheet: styleSheet,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Skip markdown for previously failed content
    if (_hasError) {
      return _buildPlainText();
    }

    final sanitized = _sanitizeForStreaming(widget.text);
    final contentHash = sanitized.hashCode;

    // Return cached widget if content hasn't changed
    // This prevents flutter_markdown from re-parsing on didChangeDependencies
    // which can cause _inlines.isEmpty assertion errors
    if (_cachedMarkdown != null && _cachedHash == contentHash) {
      return _cachedMarkdown!;
    }

    // Track what we're rendering so global error handler can attribute errors
    currentlyRenderingMarkdown = widget.text;
    try {
      _cachedMarkdown = _buildMarkdown(sanitized);
      _cachedHash = contentHash;
      return _cachedMarkdown!;
    } finally {
      currentlyRenderingMarkdown = null;
    }
  }
}

