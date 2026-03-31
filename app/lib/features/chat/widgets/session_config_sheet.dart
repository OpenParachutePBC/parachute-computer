import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import '../models/chat_session.dart';
import '../providers/chat_session_providers.dart';
import '../services/chat_service.dart';

/// Bottom sheet for bot session activation and configuration.
///
/// Shows platform info for bot sessions, response mode selector,
/// mention pattern, and activation/deny buttons for pending sessions.
class SessionConfigSheet extends ConsumerStatefulWidget {
  final ChatSession session;

  const SessionConfigSheet({super.key, required this.session});

  /// Shows the config sheet as a modal bottom sheet.
  /// Returns `true` if config was saved, `null` otherwise.
  static Future<bool?> show(BuildContext context, ChatSession session) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SessionConfigSheet(session: session),
    );
  }

  @override
  ConsumerState<SessionConfigSheet> createState() => _SessionConfigSheetState();
}

class _SessionConfigSheetState extends ConsumerState<SessionConfigSheet> {
  late String _responseMode;
  late TextEditingController _mentionPatternController;
  bool _isSaving = false;
  String? _error;

  bool get _isActivation => widget.session.isPendingInitialization;
  bool get _isBotSession => widget.session.source.isBotSession;

  @override
  void initState() {
    super.initState();
    // Default response mode: DMs get all_messages, groups get mention_only
    final isDm = widget.session.linkedBotChatType == 'dm';
    _responseMode = widget.session.responseMode ?? (isDm ? 'all_messages' : 'mention_only');
    _mentionPatternController = TextEditingController(
      text: widget.session.mentionPattern ?? '',
    );
  }

  @override
  void dispose() {
    _mentionPatternController.dispose();
    super.dispose();
  }

  Future<void> _deny() async {
    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final service = ref.read(chatServiceProvider);
      await service.denyPairing(widget.session.pairingRequestId!);
      ref.invalidate(chatSessionsProvider);
      ref.invalidate(pendingPairingCountProvider);

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Deny failed: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

      final body = <String, dynamic>{};

      // Include response settings for bot sessions
      if (_isBotSession) {
        body['responseMode'] = _responseMode;
        final pattern = _mentionPatternController.text.trim();
        body['mentionPattern'] = pattern.isNotEmpty ? pattern : '';
      }

      final http.Response response;
      if (_isActivation) {
        // POST /api/chat/{id}/activate for pending sessions
        response = await http.post(
          Uri.parse('$serverUrl/api/chat/${widget.session.id}/activate'),
          headers: headers,
          body: json.encode(body),
        );
      } else {
        // PATCH /api/chat/{id}/config for existing sessions
        response = await http.patch(
          Uri.parse('$serverUrl/api/chat/${widget.session.id}/config'),
          headers: headers,
          body: json.encode(body),
        );
      }

      if (mounted) {
        if (response.statusCode == 200) {
          Navigator.of(context).pop(true);
        } else {
          setState(() => _error = 'Save failed (${response.statusCode})');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Save failed: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = widget.session;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: EdgeInsets.only(
          left: Spacing.lg,
          right: Spacing.lg,
          top: Spacing.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: Spacing.md),

            // Title
            Text(
              _isActivation ? 'Activate Bot' : 'Bot Settings',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
            ),
            SizedBox(height: Spacing.md),

            // Scrollable content area
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Initialization banner
                    if (_isActivation) ...[
                      Container(
                        padding: EdgeInsets.all(Spacing.sm),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(Spacing.xs),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.3),
                          ),
                        ),
child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: isDark ? Colors.orange.shade300 : Colors.orange.shade700,
                            ),
                            SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                'This bot session needs configuration before it can respond.',
                                style: TextStyle(
                                  fontSize: TypographyTokens.bodySmall,
                                  color: isDark ? Colors.orange.shade300 : Colors.orange.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: Spacing.md),
                    ],

                    // Platform info header for bot sessions
                    if (session.source.isBotSession) ...[
                      Container(
                        padding: EdgeInsets.all(Spacing.sm),
                        decoration: BoxDecoration(
                          color: (isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream),
                          borderRadius: BorderRadius.circular(Spacing.xs),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              session.source == ChatSource.telegram ? Icons.send : Icons.gamepad,
                              size: 18,
                              color: session.source == ChatSource.telegram
                                  ? const Color(0xFF0088CC)
                                  : const Color(0xFF5865F2),
                            ),
                            SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                '${session.source.displayName} ${session.linkedBotChatType == "dm" ? "DM" : "Group"}',
                                style: TextStyle(
                                  fontSize: TypographyTokens.bodySmall,
                                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: Spacing.md),
                    ],

                    // Response mode for bot sessions
                    if (_isBotSession) ...[
                      Text(
                        'Response Mode',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          fontWeight: FontWeight.w500,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                      SizedBox(height: Spacing.xs),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'all_messages',
                            label: Text('All Messages', style: TextStyle(fontSize: 12)),
                          ),
                          ButtonSegment(
                            value: 'mention_only',
                            label: Text('Mentions Only', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        selected: {_responseMode},
                        onSelectionChanged: (selected) {
                          setState(() => _responseMode = selected.first);
                        },
                      ),
                      SizedBox(height: Spacing.xs),
                      Text(
                        _responseMode == 'all_messages'
                            ? 'Bot responds to every message in this chat.'
                            : 'Bot only responds when mentioned with the trigger pattern.',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),

                      // Mention pattern (shown when mention_only)
                      if (_responseMode == 'mention_only') ...[
                        SizedBox(height: Spacing.sm),
                        TextField(
                          controller: _mentionPatternController,
                          decoration: InputDecoration(
                            hintText: '@botname (default)',
                            labelText: 'Mention Pattern',
                            labelStyle: TextStyle(
                              fontSize: TypographyTokens.bodySmall,
                              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                            ),
                            hintStyle: TextStyle(
                              fontSize: TypographyTokens.bodySmall,
                              color: (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                                  .withValues(alpha: 0.5),
                            ),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: Spacing.sm,
                              vertical: Spacing.sm,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Spacing.xs),
                            ),
                          ),
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            color: isDark ? BrandColors.nightText : BrandColors.ink,
                          ),
                        ),
                      ],
                    ],

                    // Error
                    if (_error != null) ...[
                      SizedBox(height: Spacing.sm),
                      Text(
                        _error!,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: BrandColors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Deny button (only for pending approval sessions)
            if (session.isPendingApproval && session.pairingRequestId != null) ...[
              SizedBox(height: Spacing.lg),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isSaving ? null : _deny,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrandColors.error,
                    side: BorderSide(color: BrandColors.error),
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                  ),
                  child: _isSaving
                      ? SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: BrandColors.error,
                          ),
                        )
                      : const Text('Deny Request'),
                ),
              ),
            ],

            // Save / Activate button
            SizedBox(height: Spacing.lg),
            SizedBox(
              width: double.infinity,
child: ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_isActivation ? 'Activate' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
