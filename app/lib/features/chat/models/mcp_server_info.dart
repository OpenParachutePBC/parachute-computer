/// Information about an MCP server fetched from the server.
class McpServerInfo {
  final String name;
  final String displayType; // "stdio" or "http"
  final String displayCommand;
  final bool builtin;
  final List<String>? validationErrors;

  const McpServerInfo({
    required this.name,
    this.displayType = 'stdio',
    this.displayCommand = '',
    this.builtin = false,
    this.validationErrors,
  });

  factory McpServerInfo.fromJson(Map<String, dynamic> json) {
    return McpServerInfo(
      name: json['name'] as String,
      displayType: json['displayType'] as String? ?? 'stdio',
      displayCommand: json['displayCommand'] as String? ?? '',
      builtin: json['builtin'] as bool? ?? false,
      validationErrors: (json['validationErrors'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );
  }
}
