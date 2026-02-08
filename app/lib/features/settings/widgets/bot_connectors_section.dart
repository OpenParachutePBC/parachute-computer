import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart';

/// Bot connectors (Telegram, Discord) status and settings section.
class BotConnectorsSection extends ConsumerStatefulWidget {
  const BotConnectorsSection({super.key});

  @override
  ConsumerState<BotConnectorsSection> createState() => _BotConnectorsSectionState();
}

class _BotConnectorsSectionState extends ConsumerState<BotConnectorsSection> {
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _config;
  bool _isLoading = false;
  bool _isSaving = false;
  String? _error;

  // Pairing requests
  List<Map<String, dynamic>> _pendingRequests = [];
  int _pendingCount = 0;

  // Telegram controllers
  final _tgTokenController = TextEditingController();
  final _tgAllowedUsersController = TextEditingController();
  bool _tgEnabled = false;
  String _tgDmTrust = 'vault';
  String _tgGroupTrust = 'sandboxed';
  bool _tgTokenVisible = false;

  // Discord controllers
  final _dcTokenController = TextEditingController();
  final _dcAllowedGuildsController = TextEditingController();
  bool _dcEnabled = false;
  String _dcDmTrust = 'vault';
  String _dcGroupTrust = 'sandboxed';
  bool _dcTokenVisible = false;

  static const _trustLevels = ['full', 'vault', 'sandboxed'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStatus());
  }

  @override
  void dispose() {
    _tgTokenController.dispose();
    _tgAllowedUsersController.dispose();
    _dcTokenController.dispose();
    _dcAllowedGuildsController.dispose();
    super.dispose();
  }

  void _populateFromConfig(Map<String, dynamic> config) {
    final tg = config['telegram'] as Map<String, dynamic>? ?? {};
    final dc = config['discord'] as Map<String, dynamic>? ?? {};

    _tgEnabled = tg['enabled'] == true;
    _tgDmTrust = (tg['dm_trust_level'] as String?) ?? 'vault';
    _tgGroupTrust = (tg['group_trust_level'] as String?) ?? 'sandboxed';
    final tgUsers = tg['allowed_users'] as List<dynamic>? ?? [];
    _tgAllowedUsersController.text = tgUsers.join(', ');
    // Don't populate token - server doesn't return it for security

    _dcEnabled = dc['enabled'] == true;
    _dcDmTrust = (dc['dm_trust_level'] as String?) ?? 'vault';
    _dcGroupTrust = (dc['group_trust_level'] as String?) ?? 'sandboxed';
    final dcGuilds = dc['allowed_guilds'] as List<dynamic>? ?? [];
    _dcAllowedGuildsController.text = dcGuilds.join(', ');
  }

  Future<void> _loadStatus() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);
      final headers = {
        if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

      final statusResponse = await http.get(
        Uri.parse('$serverUrl/api/bots/status'),
        headers: headers,
      );

      final configResponse = await http.get(
        Uri.parse('$serverUrl/api/bots/config'),
        headers: headers,
      );

      // Fetch pairing requests
      final pairingResponse = await http.get(
        Uri.parse('$serverUrl/api/bots/pairing'),
        headers: headers,
      );

      if (mounted) {
        if (statusResponse.statusCode == 200) {
          setState(() {
            _status = json.decode(statusResponse.body) as Map<String, dynamic>;
          });
        }
        if (configResponse.statusCode == 200) {
          final config = json.decode(configResponse.body) as Map<String, dynamic>;
          setState(() {
            _config = config;
          });
          _populateFromConfig(config);
        }
        if (pairingResponse.statusCode == 200) {
          final pairingData = json.decode(pairingResponse.body) as Map<String, dynamic>;
          final requests = (pairingData['requests'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ?? [];
          setState(() {
            _pendingRequests = requests;
            _pendingCount = requests.length;
          });
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load bot status: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      // Parse allowed users as list of ints
      final tgUsersRaw = _tgAllowedUsersController.text.trim();
      final tgUsers = tgUsersRaw.isEmpty
          ? <int>[]
          : tgUsersRaw
              .split(RegExp(r'[,\s]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => int.tryParse(s.trim()))
              .whereType<int>()
              .toList();

      // Parse allowed guilds as list of strings
      final dcGuildsRaw = _dcAllowedGuildsController.text.trim();
      final dcGuilds = dcGuildsRaw.isEmpty
          ? <String>[]
          : dcGuildsRaw
              .split(RegExp(r'[,\s]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => s.trim())
              .toList();

      final body = {
        'telegram': {
          'enabled': _tgEnabled,
          'dm_trust_level': _tgDmTrust,
          'group_trust_level': _tgGroupTrust,
          'allowed_users': tgUsers,
          if (_tgTokenController.text.isNotEmpty) 'bot_token': _tgTokenController.text,
        },
        'discord': {
          'enabled': _dcEnabled,
          'dm_trust_level': _dcDmTrust,
          'group_trust_level': _dcGroupTrust,
          'allowed_guilds': dcGuilds,
          if (_dcTokenController.text.isNotEmpty) 'bot_token': _dcTokenController.text,
        },
      };

      final response = await http.put(
        Uri.parse('$serverUrl/api/bots/config'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: json.encode(body),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          final config = json.decode(response.body) as Map<String, dynamic>;
          setState(() => _config = config);
          _populateFromConfig(config);
          // Clear token fields after save (server won't return them)
          _tgTokenController.clear();
          _dcTokenController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Bot configuration saved'),
              backgroundColor: BrandColors.forest,
            ),
          );
          // Reload status to reflect changes
          _loadStatus();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to save: ${response.statusCode}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _toggleConnector(String platform, bool start) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final action = start ? 'start' : 'stop';
      final response = await http.post(
        Uri.parse('$serverUrl/api/bots/$platform/$action'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final success = data['success'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? '$platform connector ${start ? 'started' : 'stopped'}'
                : '${start ? 'Start' : 'Stop'} failed: ${data['error'] ?? response.statusCode}'),
            backgroundColor: success ? BrandColors.forest : BrandColors.error,
          ),
        );
        if (success) await _loadStatus();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${start ? 'Start' : 'Stop'} failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _testConnection(String platform) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.post(
        Uri.parse('$serverUrl/api/bots/$platform/test'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final success = data['success'] == true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? '$platform connection successful${data['bot_name'] != null ? ' (${data['bot_name']})' : ''}'
                : '$platform test failed: ${data['error'] ?? response.statusCode}'),
            backgroundColor: success ? BrandColors.forest : BrandColors.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Test failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _approvePairing(String requestId, String trustLevel) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.post(
        Uri.parse('$serverUrl/api/bots/pairing/$requestId/approve'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: json.encode({'trust_level': trustLevel}),
      );

      if (mounted) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('User approved'),
              backgroundColor: BrandColors.forest,
            ),
          );
          _loadStatus(); // Refresh
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Approval failed: ${response.statusCode}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Approval failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _denyPairing(String requestId) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      await http.post(
        Uri.parse('$serverUrl/api/bots/pairing/$requestId/deny'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Request denied'),
            backgroundColor: BrandColors.driftwood,
          ),
        );
        _loadStatus(); // Refresh
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deny failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Bot Connectors',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            if (_pendingCount > 0) ...[
              SizedBox(width: Spacing.sm),
              Container(
                padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
                decoration: BoxDecoration(
                  color: BrandColors.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$_pendingCount',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: BrandColors.error,
                  ),
                ),
              ),
            ],
          ],
        ),
        SizedBox(height: Spacing.md),

        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(
            _error!,
            style: TextStyle(
              color: BrandColors.error,
              fontSize: TypographyTokens.bodySmall,
            ),
          )
        else ...[
          // Pending pairing requests
          if (_pendingRequests.isNotEmpty) ...[
            _buildPairingRequestsSection(isDark),
            SizedBox(height: Spacing.lg),
          ],

          // Telegram section
          _buildPlatformSection(
            label: 'Telegram',
            platform: 'telegram',
            icon: Icons.telegram,
            isDark: isDark,
            enabled: _tgEnabled,
            onEnabledChanged: (v) => setState(() => _tgEnabled = v),
            tokenController: _tgTokenController,
            tokenVisible: _tgTokenVisible,
            onToggleTokenVisibility: () => setState(() => _tgTokenVisible = !_tgTokenVisible),
            dmTrust: _tgDmTrust,
            onDmTrustChanged: (v) => setState(() => _tgDmTrust = v),
            groupTrust: _tgGroupTrust,
            onGroupTrustChanged: (v) => setState(() => _tgGroupTrust = v),
            allowedLabel: 'Allowed User IDs',
            allowedHint: 'Comma-separated Telegram user IDs',
            allowedController: _tgAllowedUsersController,
            hasToken: _config?['telegram']?['has_token'] == true,
          ),

          SizedBox(height: Spacing.lg),

          // Discord section
          _buildPlatformSection(
            label: 'Discord',
            platform: 'discord',
            icon: Icons.forum_outlined,
            isDark: isDark,
            enabled: _dcEnabled,
            onEnabledChanged: (v) => setState(() => _dcEnabled = v),
            tokenController: _dcTokenController,
            tokenVisible: _dcTokenVisible,
            onToggleTokenVisibility: () => setState(() => _dcTokenVisible = !_dcTokenVisible),
            dmTrust: _dcDmTrust,
            onDmTrustChanged: (v) => setState(() => _dcDmTrust = v),
            groupTrust: _dcGroupTrust,
            onGroupTrustChanged: (v) => setState(() => _dcGroupTrust = v),
            allowedLabel: 'Allowed Guild IDs',
            allowedHint: 'Comma-separated Discord guild IDs',
            allowedController: _dcAllowedGuildsController,
            hasToken: _config?['discord']?['has_token'] == true,
          ),

          // Save button
          SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _saveConfig,
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
                  : const Text('Save Configuration'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPlatformSection({
    required String label,
    required String platform,
    required IconData icon,
    required bool isDark,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    required TextEditingController tokenController,
    required bool tokenVisible,
    required VoidCallback onToggleTokenVisibility,
    required String dmTrust,
    required ValueChanged<String> onDmTrustChanged,
    required String groupTrust,
    required ValueChanged<String> onGroupTrustChanged,
    required String allowedLabel,
    required String allowedHint,
    required TextEditingController allowedController,
    required bool hasToken,
  }) {
    final connectors = _status?['connectors'] as Map<String, dynamic>?;
    final connectorStatus = connectors?[platform] as Map<String, dynamic>?;
    final isRunning = connectorStatus?['running'] == true;

    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.cream,
        borderRadius: BorderRadius.circular(Spacing.sm),
        border: Border.all(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with enable switch
          Row(
            children: [
              Icon(icon, size: 20, color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.ink,
                  ),
                ),
              ),
              if (isRunning)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: BrandColors.forest.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Running',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: BrandColors.forest,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              SizedBox(width: Spacing.sm),
              Switch.adaptive(
                value: enabled,
                onChanged: onEnabledChanged,
                activeTrackColor: BrandColors.forest,
              ),
            ],
          ),

          SizedBox(height: Spacing.sm),

          // Bot token
          TextField(
            controller: tokenController,
            obscureText: !tokenVisible,
            decoration: InputDecoration(
              labelText: 'Bot Token',
              hintText: hasToken ? 'Token configured (leave empty to keep)' : 'Enter bot token',
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(tokenVisible ? Icons.visibility_off : Icons.visibility, size: 18),
                onPressed: onToggleTokenVisibility,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Spacing.xs),
              ),
            ),
            style: TextStyle(fontSize: TypographyTokens.bodySmall),
          ),

          SizedBox(height: Spacing.sm),

          // Allowed users/guilds
          TextField(
            controller: allowedController,
            decoration: InputDecoration(
              labelText: allowedLabel,
              hintText: allowedHint,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Spacing.xs),
              ),
            ),
            style: TextStyle(fontSize: TypographyTokens.bodySmall),
          ),

          SizedBox(height: Spacing.sm),

          // Trust level dropdowns
          Row(
            children: [
              Expanded(
                child: _buildTrustDropdown(
                  label: 'DM Trust',
                  value: dmTrust,
                  onChanged: onDmTrustChanged,
                  isDark: isDark,
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: _buildTrustDropdown(
                  label: 'Group Trust',
                  value: groupTrust,
                  onChanged: onGroupTrustChanged,
                  isDark: isDark,
                ),
              ),
            ],
          ),

          // Action buttons
          if (enabled && hasToken) ...[
            SizedBox(height: Spacing.sm),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _testConnection(platform),
                  icon: const Icon(Icons.wifi_tethering, size: 16),
                  label: const Text('Test'),
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
                SizedBox(width: Spacing.sm),
                TextButton.icon(
                  onPressed: () => _toggleConnector(platform, !isRunning),
                  icon: Icon(
                    isRunning ? Icons.stop_circle_outlined : Icons.play_circle_outlined,
                    size: 16,
                  ),
                  label: Text(isRunning ? 'Stop' : 'Start'),
                  style: TextButton.styleFrom(
                    foregroundColor: isRunning
                        ? BrandColors.error
                        : (isDark ? BrandColors.nightForest : BrandColors.forest),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPairingRequestsSection(bool isDark) {
    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: BrandColors.error.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Spacing.sm),
        border: Border.all(
          color: BrandColors.error.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_add_outlined, size: 18, color: BrandColors.error),
              SizedBox(width: Spacing.xs),
              Text(
                'Pending Approval Requests',
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          ..._pendingRequests.map((request) {
            final platform = request['platform'] as String? ?? '';
            final userDisplay = request['platformUserDisplay'] as String? ?? 'Unknown';
            final userId = request['platformUserId'] as String? ?? '';
            final requestId = request['id'] as String? ?? '';

            return Padding(
              padding: EdgeInsets.only(bottom: Spacing.sm),
              child: Row(
                children: [
                  Icon(
                    platform == 'telegram' ? Icons.send : Icons.gamepad,
                    size: 16,
                    color: platform == 'telegram'
                        ? const Color(0xFF0088CC)
                        : const Color(0xFF5865F2),
                  ),
                  SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userDisplay,
                          style: TextStyle(
                            fontSize: TypographyTokens.bodySmall,
                            fontWeight: FontWeight.w500,
                            color: isDark ? BrandColors.nightText : BrandColors.ink,
                          ),
                        ),
                        Text(
                          '${platform.isNotEmpty ? platform[0].toUpperCase() + platform.substring(1) : ''} (ID: $userId)',
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _approvePairing(requestId, 'vault'),
                    style: TextButton.styleFrom(
                      foregroundColor: BrandColors.forest,
                      padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Approve'),
                  ),
                  TextButton(
                    onPressed: () => _denyPairing(requestId),
                    style: TextButton.styleFrom(
                      foregroundColor: BrandColors.error,
                      padding: EdgeInsets.symmetric(horizontal: Spacing.xs),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Deny'),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTrustDropdown({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    required bool isDark,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.xxs),
        Container(
          padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
            borderRadius: BorderRadius.circular(Spacing.xs),
          ),
          child: DropdownButton<String>(
            value: _trustLevels.contains(value) ? value : 'vault',
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: _trustLevels.map((level) {
              return DropdownMenuItem(
                value: level,
                child: Text(
                  level[0].toUpperCase() + level.substring(1),
                  style: TextStyle(fontSize: TypographyTokens.bodySmall),
                ),
              );
            }).toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}
