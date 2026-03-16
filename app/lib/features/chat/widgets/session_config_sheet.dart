import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';
import '../models/chat_session.dart';
import '../providers/chat_session_providers.dart';
import '../models/container_env.dart';
import '../providers/container_providers.dart';
import '../services/chat_service.dart';
import '../../settings/models/trust_level.dart';

/// Bottom sheet for editing per-session configuration.
///
/// Shows platform info for bot sessions, trust level selector,
/// workspace picker, response mode for bot sessions, and activation mode
/// for pending sessions. Saves via PATCH /api/chat/{id}/config or
/// POST /api/chat/{id}/activate.
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
  late String _trustLevel;
  late String _responseMode;
  late TextEditingController _mentionPatternController;
  late TextEditingController _workspaceNameController;
  String? _containerId;
  bool _isSaving = false;
  bool _isNaming = false;
  String? _error;

  static const _trustLevels = ['direct', 'sandboxed'];

  /// UUID v4 pattern — unnamed containers have UUID slugs.
  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Whether the session's container is unnamed (UUID slug).
  bool get _hasUnnamedContainer =>
      _containerId != null && _uuidPattern.hasMatch(_containerId!);

  bool get _isActivation => widget.session.isPendingInitialization;
  bool get _isBotSession => widget.session.source.isBotSession;

  @override
  void initState() {
    super.initState();
    _trustLevel = TrustLevel.fromString(widget.session.trustLevel).name;
    _containerId = widget.session.containerId;
    // Default response mode: DMs get all_messages, groups get mention_only
    final isDm = widget.session.linkedBotChatType == 'dm';
    _responseMode = widget.session.responseMode ?? (isDm ? 'all_messages' : 'mention_only');
    _mentionPatternController = TextEditingController(
      text: widget.session.mentionPattern ?? '',
    );
    _workspaceNameController = TextEditingController();
  }

  @override
  void dispose() {
    _mentionPatternController.dispose();
    _workspaceNameController.dispose();
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

      final body = <String, dynamic>{
        'trustLevel': _trustLevel,
        // Send empty string to clear, or the slug to set
        'containerId': _containerId ?? '',
      };

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

  Color _trustColor(String level) {
    return TrustLevel.fromString(level).iconColor(
      Theme.of(context).brightness == Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = widget.session;
    final containerEnvsAsync = ref.watch(containersProvider);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
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
              _isActivation ? 'Activate Session' : 'Session Settings',
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

          // Trust level selector
          Text(
            'Trust Level',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.xs),
          SegmentedButton<String>(
            segments: _trustLevels.map((level) {
              final tl = TrustLevel.fromString(level);
              return ButtonSegment(
                value: level,
                label: Text(
                  tl.displayName,
                  style: TextStyle(fontSize: TypographyTokens.labelSmall),
                ),
              );
            }).toList(),
            selected: {_trustLevel},
            onSelectionChanged: (selected) {
              setState(() => _trustLevel = selected.first);
            },
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return _trustColor(_trustLevel).withValues(alpha: 0.15);
                }
                return null;
              }),
            ),
          ),
          SizedBox(height: Spacing.xs),
          Text(
            TrustLevel.fromString(_trustLevel).description,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),

          // Container env picker
          SizedBox(height: Spacing.md),
          _buildContainerPicker(isDark, containerEnvsAsync),

          // Sandbox info for sandboxed sessions
          if (_trustLevel == 'sandboxed') ...[
            SizedBox(height: Spacing.md),
            _buildSandboxInfo(isDark, session),
          ],

          // Response mode for bot sessions
          if (_isBotSession) ...[
            SizedBox(height: Spacing.lg),
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

  Future<void> _nameWorkspace() async {
    final name = _workspaceNameController.text.trim();
    if (name.isEmpty || _containerId == null) return;

    setState(() => _isNaming = true);
    try {
      final service = ref.read(containerServiceProvider);
      await service.updateContainer(_containerId!, displayName: name);
      ref.invalidate(containersProvider);
      if (mounted) {
        setState(() {
          _isNaming = false;
          _workspaceNameController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Workspace named "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to name workspace: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isNaming = false);
    }
  }

  Widget _buildContainerPicker(bool isDark, AsyncValue<List<ContainerEnv>> containerEnvsAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Workspace',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            fontWeight: FontWeight.w500,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.xs),

        // Promotion banner for unnamed containers
        if (_hasUnnamedContainer) ...[
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                  .withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(Spacing.xs),
              border: Border.all(
                color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                    .withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        'This session runs in an unnamed workspace. Name it to find it later.',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark ? BrandColors.nightText : BrandColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Spacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _workspaceNameController,
                        decoration: InputDecoration(
                          hintText: 'Workspace name',
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
                    ),
                    SizedBox(width: Spacing.sm),
                    SizedBox(
                      height: 36,
                      child: FilledButton(
                        onPressed: _isNaming ? null : _nameWorkspace,
                        style: FilledButton.styleFrom(
                          backgroundColor: isDark
                              ? BrandColors.nightForest
                              : BrandColors.forest,
                          padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
                        ),
                        child: _isNaming
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Name'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.sm),
        ],

        // Workspace dropdown
        containerEnvsAsync.when(
          data: (envs) {
            // Build items: the current unnamed container (if any) + named envs
            final items = <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: null,
                child: Text(
                  'Private',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ),
            ];

            // If the current containerId is a UUID not in the envs list,
            // add it as a special item so DropdownButton doesn't error
            if (_containerId != null &&
                !envs.any((e) => e.slug == _containerId)) {
              items.add(DropdownMenuItem<String>(
                value: _containerId,
                child: Text(
                  'Unnamed sandbox',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    fontStyle: FontStyle.italic,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ));
            }

            items.addAll(envs.map((env) => DropdownMenuItem<String>(
              value: env.slug,
              child: Text(env.displayName),
            )));

            return Container(
              padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Spacing.xs),
                border: Border.all(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                ),
              ),
              child: DropdownButton<String>(
                value: _containerId,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
                items: items,
                onChanged: (value) {
                  setState(() => _containerId = value);
                },
              ),
            );
          },
          loading: () => SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          error: (_, __) => Text(
            'Failed to load workspaces',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: BrandColors.error,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSandboxInfo(bool isDark, ChatSession session) {
    return Container(
      padding: EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : Colors.blue.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Spacing.xs),
        border: Border.all(
          color: Colors.blue.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sandbox Info',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.ink,
            ),
          ),
          SizedBox(height: Spacing.xs),
          _buildInfoRow(
            isDark,
            Icons.folder_outlined,
            'Directory',
            session.workingDirectory ?? 'vault root',
          ),
          _buildInfoRow(
            isDark,
            Icons.memory_outlined,
            'Resources',
            '512MB, 1 CPU',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(bool isDark, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(width: Spacing.xs),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightText : BrandColors.ink,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
