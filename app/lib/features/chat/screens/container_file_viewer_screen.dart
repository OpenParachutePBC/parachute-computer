import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/vault/models/file_item.dart';
import '../providers/container_files_providers.dart';

/// Viewer for text and markdown files in a container env's home directory.
///
/// Downloads the file via [ContainerFilesService.downloadFile] on first load,
/// then renders as markdown or plain monospace text based on [file.isMarkdown].
class ContainerFileViewerScreen extends ConsumerStatefulWidget {
  final String slug;
  final FileItem file;

  const ContainerFileViewerScreen({
    super.key,
    required this.slug,
    required this.file,
  });

  @override
  ConsumerState<ContainerFileViewerScreen> createState() =>
      _ContainerFileViewerScreenState();
}

class _ContainerFileViewerScreenState
    extends ConsumerState<ContainerFileViewerScreen> {
  bool _isLoading = true;
  String? _error;
  String _content = '';

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final service = ref.read(containerFilesServiceProvider);
      final bytes = await service.downloadFile(widget.slug, widget.file.path);
      final text = _bytesToString(bytes);
      if (mounted) {
        setState(() {
          _content = text;
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

  String _bytesToString(Uint8List bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.file.name,
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            fontSize: TypographyTokens.titleMedium,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            onPressed: _loadFile,
            tooltip: 'Reload',
          ),
        ],
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: BrandColors.error),
              const SizedBox(height: Spacing.md),
              Text(
                'Failed to load file',
                style: TextStyle(
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  fontSize: TypographyTokens.titleMedium,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                _error!,
                style: TextStyle(
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                  fontSize: TypographyTokens.bodySmall,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.lg),
              FilledButton(onPressed: _loadFile, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (widget.file.isMarkdown) {
      return _buildMarkdownViewer(isDark);
    }

    return _buildTextViewer(isDark);
  }

  Widget _buildTextViewer(bool isDark) {
    return Container(
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      child: Scrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.md),
          child: SelectableText(
            _content,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownViewer(bool isDark) {
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.md),
      child: MarkdownBody(
        data: _content,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(
            color: textColor,
            fontSize: TypographyTokens.bodyMedium,
            height: TypographyTokens.lineHeightRelaxed,
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
          code: TextStyle(
            color: textColor,
            backgroundColor: isDark
                ? BrandColors.nightSurfaceElevated
                : BrandColors.softWhite,
            fontFamily: 'monospace',
          ),
          a: TextStyle(
            color:
                isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
