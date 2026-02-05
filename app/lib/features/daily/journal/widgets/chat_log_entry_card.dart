import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/services/deep_link_service.dart';
import '../models/chat_log.dart';

/// Shared widget for rendering a chat log entry card
/// Used by both ChatLogSection and CollapsibleChatLogSection
class ChatLogEntryCard extends ConsumerWidget {
  final ChatLogEntry entry;
  final bool useDeepLinks;

  const ChatLogEntryCard({
    super.key,
    required this.entry,
    this.useDeepLinks = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? BrandColors.charcoal.withValues(alpha: 0.3)
              : BrandColors.stone.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: BrandColors.turquoise.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.smart_toy_outlined,
                  size: 16,
                  color: BrandColors.turquoise,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark ? BrandColors.softWhite : BrandColors.ink,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatTime(entry.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: BrandColors.driftwood,
                      ),
                    ),
                  ],
                ),
              ),
              if (entry.sessionId != null)
                IconButton(
                  icon: Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: useDeepLinks ? BrandColors.turquoise : BrandColors.forest,
                  ),
                  onPressed: useDeepLinks
                      ? () {
                          // Navigate to chat session via deep link
                          final deepLinkService = ref.read(deepLinkServiceProvider);
                          final url = DeepLinkService.chatSessionUrl(entry.sessionId!);
                          deepLinkService.handleDeepLink(url);
                        }
                      : () {
                          // TODO: Open session in Parachute chat
                          debugPrint('Open session: ${entry.sessionId}');
                        },
                  tooltip: 'Open session',
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),

          // Content preview (markdown rendered)
          if (entry.hasContent) ...[
            const SizedBox(height: 8),
            MarkdownBody(
              data: entry.content,
              selectable: true,
              shrinkWrap: true,
              onTapLink: (text, href, title) {
                if (href != null) {
                  launchUrl(Uri.parse(href));
                }
              },
              styleSheet: MarkdownStyleSheet(
                p: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  height: 1.4,
                ),
                h1: theme.textTheme.titleSmall?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                h2: theme.textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                listBullet: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                ),
                a: theme.textTheme.bodySmall?.copyWith(
                  color: BrandColors.turquoise,
                  decoration: TextDecoration.underline,
                ),
                strong: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                em: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    return '$displayHour:$minute $period';
  }
}
