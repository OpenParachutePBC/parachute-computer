/// Metadata about the system prompt composition for transparency.
///
/// This is sent as a `prompt_metadata` event after the session event
/// to show users what's going into their system prompt.
class PromptMetadata {
  /// Source of the base prompt: 'default', 'module', 'agent', 'custom'
  final String promptSource;

  /// Path to prompt file if from module/agent (e.g., 'Chat/CLAUDE.md')
  final String? promptSourcePath;

  /// List of context files that were loaded
  final List<String> contextFiles;

  /// Estimated tokens from context files
  final int contextTokens;

  /// Whether context was truncated due to token limit
  final bool contextTruncated;

  /// Name of the agent being used
  final String? agentName;

  /// List of specialized agents available
  final List<String> availableAgents;

  /// Estimated tokens in the base prompt
  final int basePromptTokens;

  /// Total estimated tokens in the complete system prompt
  final int totalPromptTokens;

  /// Whether trust mode is enabled (bypasses permission checks)
  final bool trustMode;

  /// Path to CLAUDE.md in working directory (if found)
  final String? workingDirectoryClaudeMd;

  const PromptMetadata({
    required this.promptSource,
    this.promptSourcePath,
    this.contextFiles = const [],
    this.contextTokens = 0,
    this.contextTruncated = false,
    this.agentName,
    this.availableAgents = const [],
    this.basePromptTokens = 0,
    this.totalPromptTokens = 0,
    this.trustMode = true,
    this.workingDirectoryClaudeMd,
  });

  factory PromptMetadata.fromJson(Map<String, dynamic> json) {
    return PromptMetadata(
      promptSource: json['promptSource'] as String? ?? 'default',
      promptSourcePath: json['promptSourcePath'] as String?,
      contextFiles:
          (json['contextFiles'] as List<dynamic>?)?.cast<String>() ?? [],
      contextTokens: json['contextTokens'] as int? ?? 0,
      contextTruncated: json['contextTruncated'] as bool? ?? false,
      agentName: json['agentName'] as String?,
      availableAgents:
          (json['availableAgents'] as List<dynamic>?)?.cast<String>() ?? [],
      basePromptTokens: json['basePromptTokens'] as int? ?? 0,
      totalPromptTokens: json['totalPromptTokens'] as int? ?? 0,
      trustMode: json['trustMode'] as bool? ?? true,
      workingDirectoryClaudeMd: json['workingDirectoryClaudeMd'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'promptSource': promptSource,
      'promptSourcePath': promptSourcePath,
      'contextFiles': contextFiles,
      'contextTokens': contextTokens,
      'contextTruncated': contextTruncated,
      'agentName': agentName,
      'availableAgents': availableAgents,
      'basePromptTokens': basePromptTokens,
      'totalPromptTokens': totalPromptTokens,
      'trustMode': trustMode,
      'workingDirectoryClaudeMd': workingDirectoryClaudeMd,
    };
  }

  /// Human-readable description of the prompt source
  String get promptSourceDescription {
    switch (promptSource) {
      case 'default':
        return 'Default Parachute prompt';
      case 'module':
        return 'Custom prompt (${promptSourcePath ?? "Chat/CLAUDE.md"})';
      case 'agent':
        return 'Agent: ${agentName ?? "custom"}';
      case 'custom':
        return 'Session-specific prompt';
      default:
        return promptSource;
    }
  }

  /// Whether this is using a custom (non-default) prompt
  bool get isCustomPrompt => promptSource != 'default';

  /// Whether any context files were loaded
  bool get hasContext => contextFiles.isNotEmpty;

  PromptMetadata copyWith({
    String? promptSource,
    String? promptSourcePath,
    List<String>? contextFiles,
    int? contextTokens,
    bool? contextTruncated,
    String? agentName,
    List<String>? availableAgents,
    int? basePromptTokens,
    int? totalPromptTokens,
    bool? trustMode,
    String? workingDirectoryClaudeMd,
  }) {
    return PromptMetadata(
      promptSource: promptSource ?? this.promptSource,
      promptSourcePath: promptSourcePath ?? this.promptSourcePath,
      contextFiles: contextFiles ?? this.contextFiles,
      contextTokens: contextTokens ?? this.contextTokens,
      contextTruncated: contextTruncated ?? this.contextTruncated,
      agentName: agentName ?? this.agentName,
      availableAgents: availableAgents ?? this.availableAgents,
      basePromptTokens: basePromptTokens ?? this.basePromptTokens,
      totalPromptTokens: totalPromptTokens ?? this.totalPromptTokens,
      trustMode: trustMode ?? this.trustMode,
      workingDirectoryClaudeMd: workingDirectoryClaudeMd ?? this.workingDirectoryClaudeMd,
    );
  }

  @override
  String toString() {
    return 'PromptMetadata(source: $promptSource, tokens: $totalPromptTokens, context: ${contextFiles.length} files)';
  }
}

/// Result from the prompt preview API that includes the full prompt text.
///
/// This extends the metadata with the actual system prompt content
/// for full transparency.
class PromptPreviewResult extends PromptMetadata {
  /// The full system prompt text
  final String prompt;

  /// Working directory for the agent (if specified)
  final String? workingDirectory;

  const PromptPreviewResult({
    required this.prompt,
    this.workingDirectory,
    required super.promptSource,
    super.promptSourcePath,
    super.contextFiles = const [],
    super.contextTokens = 0,
    super.contextTruncated = false,
    super.agentName,
    super.availableAgents = const [],
    super.basePromptTokens = 0,
    super.totalPromptTokens = 0,
    super.trustMode = true,
    super.workingDirectoryClaudeMd,
  });

  factory PromptPreviewResult.fromJson(Map<String, dynamic> json) {
    return PromptPreviewResult(
      prompt: json['prompt'] as String? ?? '',
      workingDirectory: json['workingDirectory'] as String?,
      promptSource: json['promptSource'] as String? ?? 'default',
      promptSourcePath: json['promptSourcePath'] as String?,
      contextFiles:
          (json['contextFiles'] as List<dynamic>?)?.cast<String>() ?? [],
      contextTokens: json['contextTokens'] as int? ?? 0,
      contextTruncated: json['contextTruncated'] as bool? ?? false,
      agentName: json['agentName'] as String?,
      availableAgents:
          (json['availableAgents'] as List<dynamic>?)?.cast<String>() ?? [],
      basePromptTokens: json['basePromptTokens'] as int? ?? 0,
      totalPromptTokens: json['totalPromptTokens'] as int? ?? 0,
      trustMode: json['trustMode'] as bool? ?? true,
      workingDirectoryClaudeMd: json['workingDirectoryClaudeMd'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'prompt': prompt,
      'workingDirectory': workingDirectory,
    };
  }

  /// Convert to PromptMetadata (without the prompt text)
  PromptMetadata toMetadata() {
    return PromptMetadata(
      promptSource: promptSource,
      promptSourcePath: promptSourcePath,
      contextFiles: contextFiles,
      contextTokens: contextTokens,
      contextTruncated: contextTruncated,
      agentName: agentName,
      availableAgents: availableAgents,
      basePromptTokens: basePromptTokens,
      totalPromptTokens: totalPromptTokens,
      trustMode: trustMode,
      workingDirectoryClaudeMd: workingDirectoryClaudeMd,
    );
  }

  @override
  String toString() {
    return 'PromptPreviewResult(source: $promptSource, tokens: $totalPromptTokens, promptLength: ${prompt.length})';
  }
}
