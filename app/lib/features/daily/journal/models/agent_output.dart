/// Output from a daily agent (reflections, content-scout, etc.)
///
/// Agent outputs are markdown files with YAML frontmatter stored in
/// configurable paths like Daily/reflections/{date}.md or Daily/content-ideas/{date}.md
class AgentOutput {
  /// The date this output is for
  final DateTime date;

  /// The agent that produced this output
  final String agentName;

  /// The output content (markdown)
  final String content;

  /// When the output was generated
  final DateTime? generatedAt;

  /// The file path where this output is stored
  final String? filePath;

  const AgentOutput({
    required this.date,
    required this.agentName,
    required this.content,
    this.generatedAt,
    this.filePath,
  });

  /// Whether this output has content
  bool get hasContent => content.trim().isNotEmpty;

  /// Get a preview of the output (first paragraph or first N characters)
  String get preview {
    if (content.isEmpty) return '';

    // Find first paragraph break
    final paragraphEnd = content.indexOf('\n\n');
    if (paragraphEnd > 0 && paragraphEnd < 300) {
      return content.substring(0, paragraphEnd);
    }

    // Otherwise truncate at character limit
    if (content.length > 200) {
      return '${content.substring(0, 200)}...';
    }

    return content;
  }

  /// Get a title from the content (first heading or first line)
  String get title {
    // Look for first markdown heading
    final headingMatch = RegExp(r'^#+\s+(.+)$', multiLine: true).firstMatch(content);
    if (headingMatch != null) {
      return headingMatch.group(1)?.trim() ?? agentName;
    }

    // Fall back to first line
    final firstLine = content.split('\n').first.trim();
    if (firstLine.isNotEmpty && firstLine.length < 100) {
      return firstLine;
    }

    return agentName;
  }

  @override
  String toString() {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return 'AgentOutput($agentName, $dateStr, ${content.length} chars)';
  }
}


/// Configuration for a daily agent (loaded from API)
class DailyAgentConfig {
  final String name;
  final String displayName;
  final String description;
  final bool scheduleEnabled;
  final String scheduleTime;
  final String outputPath;
  final String? lastRunAt;
  final String? lastProcessedDate;
  final int runCount;

  const DailyAgentConfig({
    required this.name,
    required this.displayName,
    required this.description,
    required this.scheduleEnabled,
    required this.scheduleTime,
    required this.outputPath,
    this.lastRunAt,
    this.lastProcessedDate,
    this.runCount = 0,
  });

  factory DailyAgentConfig.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'] as Map<String, dynamic>? ?? {};
    final state = json['state'] as Map<String, dynamic>? ?? {};

    return DailyAgentConfig(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      scheduleEnabled: schedule['enabled'] as bool? ?? true,
      scheduleTime: schedule['time'] as String? ?? '03:00',
      outputPath: json['outputPath'] as String? ?? '',
      lastRunAt: state['lastRunAt'] as String? ?? json['lastRunAt'] as String?,
      lastProcessedDate: state['lastProcessedDate'] as String? ?? json['lastProcessedDate'] as String?,
      runCount: state['runCount'] as int? ?? json['runCount'] as int? ?? 0,
    );
  }

  /// Get the output directory name from the output path
  String get outputDirectory {
    // Extract directory from path like "Daily/reflections/{date}.md"
    final parts = outputPath.split('/');
    if (parts.length >= 2) {
      return parts[1]; // e.g., "reflections"
    }
    return name;
  }
}
