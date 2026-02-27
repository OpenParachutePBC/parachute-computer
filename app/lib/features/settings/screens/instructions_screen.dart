import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../../chat/providers/chat_session_providers.dart';
import '../../chat/services/chat_service.dart';

/// Instructions & Prompts settings screen.
///
/// Shows an editable personal instructions field (vault/CLAUDE.md)
/// and read-only collapsible sections for the bridge prompts.
class InstructionsScreen extends ConsumerStatefulWidget {
  const InstructionsScreen({super.key});

  @override
  ConsumerState<InstructionsScreen> createState() => _InstructionsScreenState();
}

class _InstructionsScreenState extends ConsumerState<InstructionsScreen> {
  bool _loading = true;
  String? _error;
  SettingsPrompts? _prompts;

  final _controller = TextEditingController();
  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final service = ref.read(chatServiceProvider);
      final prompts = await service.fetchPrompts();
      if (mounted) {
        setState(() {
          _prompts = prompts;
          _controller.text = prompts.vaultInstructions;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = false;
    });
    try {
      final service = ref.read(chatServiceProvider);
      await service.saveInstructions(_controller.text);
      if (mounted) {
        setState(() {
          _saving = false;
          _saved = true;
        });
        // Clear saved indicator after 2 seconds
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _saved = false);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Instructions & Prompts',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : _Body(
                  isDark: isDark,
                  controller: _controller,
                  saving: _saving,
                  saved: _saved,
                  prompts: _prompts!,
                  onSave: _save,
                ),
    );
  }
}

class _Body extends StatelessWidget {
  final bool isDark;
  final TextEditingController controller;
  final bool saving;
  final bool saved;
  final SettingsPrompts prompts;
  final VoidCallback onSave;

  const _Body({
    required this.isDark,
    required this.controller,
    required this.saving,
    required this.saved,
    required this.prompts,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Spacing.lg),
      children: [
        // ── Personal Instructions ──────────────────────────────
        _SectionCard(
          isDark: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Personal instructions',
                style: TextStyle(
                  fontSize: TypographyTokens.titleMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              SizedBox(height: Spacing.xs),
              Text(
                'Injected into every chat session. Tell the AI who you are, '
                'what you\'re working on, and what to keep in mind.',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              SizedBox(height: Spacing.md),
              TextField(
                controller: controller,
                maxLines: 10,
                minLines: 5,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'e.g. I\'m building a local-first app called Parachute. '
                      'Kevin is my collaborator on LVB. Prefer concise responses.',
                  hintStyle: TextStyle(
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                    fontSize: TypographyTokens.bodySmall,
                  ),
                  filled: true,
                  fillColor: isDark
                      ? BrandColors.nightSurface
                      : BrandColors.cream,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    borderSide: BorderSide(
                      color: isDark
                          ? Colors.white12
                          : Colors.black12,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    borderSide: BorderSide(
                      color: isDark ? Colors.white12 : Colors.black12,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    borderSide: BorderSide(
                      color: isDark
                          ? BrandColors.nightForest
                          : BrandColors.forest,
                    ),
                  ),
                  contentPadding: EdgeInsets.all(Spacing.md),
                ),
              ),
              SizedBox(height: Spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (saved)
                    Padding(
                      padding: EdgeInsets.only(right: Spacing.sm),
                      child: Text(
                        'Saved',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: saving ? null : onSave,
                    style: FilledButton.styleFrom(
                      backgroundColor: isDark
                          ? BrandColors.nightForest
                          : BrandColors.forest,
                      foregroundColor: Colors.white,
                    ),
                    child: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Save'),
                  ),
                ],
              ),
              SizedBox(height: Spacing.xs),
              Text(
                'Saved to ${prompts.vaultInstructionsPath}',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),

        SizedBox(height: Spacing.xl),

        // ── Bridge Prompts (read-only) ─────────────────────────
        Text(
          'System prompts',
          style: TextStyle(
            fontSize: TypographyTokens.labelMedium,
            fontWeight: FontWeight.w600,
            color: isDark
                ? BrandColors.nightTextSecondary
                : BrandColors.driftwood,
            letterSpacing: 0.5,
          ),
        ),
        SizedBox(height: Spacing.sm),
        _PromptExpansionTile(
          isDark: isDark,
          title: 'Bridge observe prompt',
          subtitle: 'Session title, summary, and activity logging',
          content: prompts.bridgeObservePrompt,
        ),
        SizedBox(height: Spacing.sm),
        _PromptExpansionTile(
          isDark: isDark,
          title: 'Bridge enrich prompt',
          subtitle: 'Pre-turn context enrichment from your knowledge graph',
          content: prompts.bridgeEnrichPrompt,
        ),
        SizedBox(height: Spacing.sm),
        _SectionCard(
          isDark: isDark,
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  'These are the default prompts. Custom prompting coming soon.',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ),
            ],
          ),
        ),

        SizedBox(height: Spacing.xxl),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final bool isDark;
  final Widget child;

  const _SectionCard({required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PromptExpansionTile extends StatefulWidget {
  final bool isDark;
  final String title;
  final String subtitle;
  final String content;

  const _PromptExpansionTile({
    required this.isDark,
    required this.title,
    required this.subtitle,
    required this.content,
  });

  @override
  State<_PromptExpansionTile> createState() => _PromptExpansionTileState();
}

class _PromptExpansionTileState extends State<_PromptExpansionTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: _expanded
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(Radii.md),
            child: Padding(
              padding: EdgeInsets.all(Spacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodyMedium,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? BrandColors.nightText
                                : BrandColors.charcoal,
                          ),
                        ),
                        SizedBox(height: Spacing.xxs),
                        Text(
                          widget.subtitle,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            Padding(
              padding: EdgeInsets.all(Spacing.lg),
              child: SelectableText(
                widget.content,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark
                      ? BrandColors.nightText
                      : BrandColors.charcoal,
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Failed to load settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
