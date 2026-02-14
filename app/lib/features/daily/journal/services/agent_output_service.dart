import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import '../models/agent_output.dart';

/// Service for reading daily agent outputs.
///
/// Agent outputs are markdown files with YAML frontmatter stored in
/// configurable paths like Daily/reflections/{date}.md or Daily/content-ideas/{date}.md
class AgentOutputService {
  final String _dailyPath;
  final FileSystemService _fileSystemService;
  final _log = logger.createLogger('AgentOutputService');

  AgentOutputService._({
    required String dailyPath,
    required FileSystemService fileSystemService,
  })  : _dailyPath = dailyPath,
        _fileSystemService = fileSystemService;

  /// Factory constructor
  static Future<AgentOutputService> create({
    required FileSystemService fileSystemService,
  }) async {
    // getRootPath() returns the module path, e.g., ~/Parachute/Daily
    final dailyPath = await fileSystemService.getRootPath();
    return AgentOutputService._(
      dailyPath: dailyPath,
      fileSystemService: fileSystemService,
    );
  }

  /// Get path to a specific agent's output directory
  String getAgentOutputPath(String agentOutputDir) {
    return '$_dailyPath/$agentOutputDir';
  }

  /// Get the file path for an agent output on a specific date
  String getFilePath(String agentOutputDir, DateTime date) {
    final dateStr = _formatDate(date);
    return '$_dailyPath/$agentOutputDir/$dateStr.md';
  }

  /// Check if output exists for a given agent and date
  Future<bool> hasOutput(String agentOutputDir, DateTime date) async {
    final filePath = getFilePath(agentOutputDir, date);
    return await _fileSystemService.fileExists(filePath);
  }

  /// Load output for a specific agent and date
  ///
  /// Returns null if no output exists.
  Future<AgentOutput?> loadOutput(String agentName, String agentOutputDir, DateTime date) async {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final filePath = getFilePath(agentOutputDir, normalizedDate);

    if (!await _fileSystemService.fileExists(filePath)) {
      _log.debug('No output found', data: {'agent': agentName, 'date': _formatDate(normalizedDate)});
      return null;
    }

    try {
      final content = await _fileSystemService.readFileAsString(filePath);
      if (content == null) {
        _log.debug('Output file empty', data: {'agent': agentName, 'date': _formatDate(normalizedDate)});
        return null;
      }
      return _parseOutput(content, agentName, normalizedDate, filePath);
    } catch (e) {
      _log.error('Failed to load output', error: e, data: {'agent': agentName, 'date': _formatDate(normalizedDate)});
      return null;
    }
  }

  /// Parse an agent output from markdown with YAML frontmatter
  AgentOutput _parseOutput(String content, String agentName, DateTime date, String filePath) {
    String body = content;
    DateTime? generatedAt;
    String? parsedAgentName;

    // Try to parse YAML frontmatter
    if (content.startsWith('---')) {
      final endIndex = content.indexOf('---', 3);
      if (endIndex != -1) {
        final frontmatter = content.substring(3, endIndex).trim();
        body = content.substring(endIndex + 3).trim();

        try {
          final yaml = loadYaml(frontmatter);
          if (yaml is YamlMap) {
            final generatedAtStr = yaml['generated_at'];
            if (generatedAtStr != null) {
              generatedAt = DateTime.tryParse(generatedAtStr.toString());
            }
            // Use agent name from frontmatter if available
            parsedAgentName = yaml['agent']?.toString();
          }
        } catch (e) {
          _log.warn('Failed to parse output frontmatter', error: e);
        }
      }
    }

    return AgentOutput(
      date: date,
      agentName: parsedAgentName ?? agentName,
      content: body.trim(),
      generatedAt: generatedAt,
      filePath: filePath,
    );
  }

  /// List all dates that have outputs for a specific agent
  Future<List<DateTime>> listOutputDates(String agentOutputDir) async {
    final dates = <DateTime>[];
    final outputPath = getAgentOutputPath(agentOutputDir);

    final dir = Directory(outputPath);
    if (!await dir.exists()) {
      return dates;
    }

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.md')) {
        final filename = entity.uri.pathSegments.last;
        final dateStr = filename.replaceAll('.md', '');
        final date = DateTime.tryParse(dateStr);
        if (date != null) {
          dates.add(date);
        }
      }
    }

    dates.sort((a, b) => b.compareTo(a)); // Most recent first
    return dates;
  }

  /// List outputs from all agents for a specific date
  Future<List<AgentOutput>> listOutputsForDate(List<DailyAgentConfig> agents, DateTime date) async {
    final outputs = <AgentOutput>[];

    for (final agent in agents) {
      final output = await loadOutput(agent.name, agent.outputDirectory, date);
      if (output != null && output.hasContent) {
        outputs.add(output);
      }
    }

    return outputs;
  }

  /// List all outputs from a specific agent (for browsing)
  Future<List<AgentOutput>> listAgentOutputs(String agentName, String agentOutputDir, {int limit = 30}) async {
    final outputs = <AgentOutput>[];
    final dates = await listOutputDates(agentOutputDir);

    for (final date in dates.take(limit)) {
      final output = await loadOutput(agentName, agentOutputDir, date);
      if (output != null && output.hasContent) {
        outputs.add(output);
      }
    }

    return outputs;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
