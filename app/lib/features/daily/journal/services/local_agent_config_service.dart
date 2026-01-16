import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import '../models/agent_output.dart';

/// Service for reading daily agent configurations locally from Daily/.agents/
///
/// This allows the app to discover agents and their output directories
/// without needing a server connection.
class LocalAgentConfigService {
  final String _dailyPath;
  final FileSystemService _fileSystemService;
  final _log = logger.createLogger('LocalAgentConfigService');

  LocalAgentConfigService._({
    required String dailyPath,
    required FileSystemService fileSystemService,
  })  : _dailyPath = dailyPath,
        _fileSystemService = fileSystemService;

  /// Factory constructor
  static Future<LocalAgentConfigService> create({
    required FileSystemService fileSystemService,
  }) async {
    final dailyPath = await fileSystemService.getRootPath();
    return LocalAgentConfigService._(
      dailyPath: dailyPath,
      fileSystemService: fileSystemService,
    );
  }

  /// Get the path to the agents directory
  String get agentsPath => '$_dailyPath/.agents';

  /// Discover all agent configurations from Daily/.agents/*.md
  Future<List<DailyAgentConfig>> discoverAgents() async {
    final agents = <DailyAgentConfig>[];
    final agentsDir = Directory(agentsPath);

    if (!await agentsDir.exists()) {
      _log.debug('Agents directory does not exist', data: {'path': agentsPath});
      return agents;
    }

    await for (final entity in agentsDir.list()) {
      if (entity is File && entity.path.endsWith('.md')) {
        try {
          final config = await _parseAgentFile(entity);
          if (config != null) {
            agents.add(config);
            _log.debug('Discovered agent', data: {'name': config.name});
          }
        } catch (e) {
          _log.warn('Failed to parse agent file', error: e, data: {'path': entity.path});
        }
      }
    }

    // Sort by name for consistent ordering
    agents.sort((a, b) => a.name.compareTo(b.name));
    return agents;
  }

  /// Parse a single agent configuration file
  Future<DailyAgentConfig?> _parseAgentFile(File file) async {
    final content = await file.readAsString();

    // Extract name from filename (e.g., "curator.md" -> "curator")
    final filename = file.uri.pathSegments.last;
    final name = filename.replaceAll('.md', '');

    // Parse YAML frontmatter
    if (!content.startsWith('---')) {
      _log.debug('Agent file has no frontmatter', data: {'name': name});
      // Still create a basic config with defaults
      return DailyAgentConfig(
        name: name,
        displayName: _formatDisplayName(name),
        description: '',
        scheduleEnabled: true,
        scheduleTime: '03:00',
        outputPath: 'Daily/$name/{date}.md',
      );
    }

    final endIndex = content.indexOf('---', 3);
    if (endIndex == -1) {
      _log.warn('Malformed frontmatter', data: {'name': name});
      return null;
    }

    final frontmatter = content.substring(3, endIndex).trim();

    try {
      final yaml = loadYaml(frontmatter);
      if (yaml is! YamlMap) {
        return null;
      }

      // Parse schedule
      final schedule = yaml['schedule'];
      bool scheduleEnabled = true;
      String scheduleTime = '03:00';

      if (schedule is String) {
        scheduleTime = schedule;
      } else if (schedule is YamlMap) {
        scheduleEnabled = schedule['enabled'] as bool? ?? true;
        scheduleTime = schedule['time'] as String? ?? '03:00';
      }

      // Parse output path
      final output = yaml['output'];
      String outputPath;

      if (output is String) {
        outputPath = output;
      } else if (output is YamlMap) {
        outputPath = output['path'] as String? ?? 'Daily/$name/{date}.md';
      } else {
        // Default output path based on agent name
        outputPath = 'Daily/$name/{date}.md';
      }

      return DailyAgentConfig(
        name: name,
        displayName: yaml['displayName'] as String? ?? _formatDisplayName(name),
        description: yaml['description'] as String? ?? '',
        scheduleEnabled: scheduleEnabled,
        scheduleTime: scheduleTime,
        outputPath: outputPath,
      );
    } catch (e) {
      _log.error('Failed to parse YAML', error: e, data: {'name': name});
      return null;
    }
  }

  /// Format a kebab-case name as a display name
  String _formatDisplayName(String name) {
    return name
        .split('-')
        .map((word) => word.isNotEmpty
            ? '${word[0].toUpperCase()}${word.substring(1)}'
            : word)
        .join(' ');
  }

  /// Get configuration for a specific agent by name
  Future<DailyAgentConfig?> getAgent(String name) async {
    final file = File('$agentsPath/$name.md');
    if (!await file.exists()) {
      return null;
    }
    return _parseAgentFile(file);
  }

  /// Check if an agent exists
  Future<bool> agentExists(String name) async {
    final file = File('$agentsPath/$name.md');
    return await file.exists();
  }
}
