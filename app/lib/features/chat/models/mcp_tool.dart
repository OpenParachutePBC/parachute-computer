/// A tool exposed by an MCP server.
class McpTool {
  final String name;
  final String? description;

  const McpTool({required this.name, this.description});

  factory McpTool.fromJson(Map<String, dynamic> json) {
    return McpTool(
      name: json['name'] as String,
      description: json['description'] as String?,
    );
  }
}
