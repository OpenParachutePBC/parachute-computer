part of 'chat_service.dart';

/// Extension to add vault migration functionality to ChatService
extension ChatServiceMigration on ChatService {
  /// Scan sessions to find those needing vault path migration
  Future<MigrationScanResult?> scanMigration() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/migration/scan'),
        headers: defaultHeaders,
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        debugPrint('[ChatService] Migration scan failed: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return MigrationScanResult.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error scanning migration: $e');
      return null;
    }
  }

  /// Migrate all sessions to the current vault root
  Future<MigrationResult> migrateAllSessions({bool copyTranscripts = true}) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/migration/all'),
        headers: defaultHeaders,
        body: jsonEncode({'copyTranscripts': copyTranscripts}),
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        return MigrationResult.error('Migration failed: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return MigrationResult.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error migrating sessions: $e');
      return MigrationResult.error(e.toString());
    }
  }

  /// Migrate a single session
  Future<bool> migrateSession(String sessionId, {bool copyTranscript = true}) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/migration/session/${Uri.encodeComponent(sessionId)}'),
        headers: defaultHeaders,
        body: jsonEncode({'copyTranscript': copyTranscript}),
      ).timeout(const Duration(seconds: 30));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[ChatService] Error migrating session: $e');
      return false;
    }
  }
}

/// Data class for migration scan results
class MigrationScanResult {
  final String currentVaultRoot;
  final List<SessionMigrationInfo> needsMigration;
  final int alreadyCurrent;
  final int noVaultRoot;
  final int total;

  MigrationScanResult({
    required this.currentVaultRoot,
    required this.needsMigration,
    required this.alreadyCurrent,
    required this.noVaultRoot,
    required this.total,
  });

  factory MigrationScanResult.fromJson(Map<String, dynamic> json) {
    final needsMigration = (json['needsMigration'] as List<dynamic>?)
            ?.map((e) => SessionMigrationInfo.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    return MigrationScanResult(
      currentVaultRoot: json['currentVaultRoot'] as String? ?? '',
      needsMigration: needsMigration,
      alreadyCurrent: json['alreadyCurrent'] as int? ?? 0,
      noVaultRoot: json['noVaultRoot'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
    );
  }
}

/// Info about a session that needs migration
class SessionMigrationInfo {
  final String sessionId;
  final String title;
  final String oldVaultRoot;
  final String? workingDirectory;
  final bool transcriptExists;
  final String? transcriptPath;
  final String? createdAt;

  SessionMigrationInfo({
    required this.sessionId,
    required this.title,
    required this.oldVaultRoot,
    this.workingDirectory,
    required this.transcriptExists,
    this.transcriptPath,
    this.createdAt,
  });

  factory SessionMigrationInfo.fromJson(Map<String, dynamic> json) {
    return SessionMigrationInfo(
      sessionId: json['sessionId'] as String? ?? '',
      title: json['title'] as String? ?? '(untitled)',
      oldVaultRoot: json['oldVaultRoot'] as String? ?? '',
      workingDirectory: json['workingDirectory'] as String?,
      transcriptExists: json['transcriptExists'] as bool? ?? false,
      transcriptPath: json['transcriptPath'] as String?,
      createdAt: json['createdAt'] as String?,
    );
  }
}

/// Result of migrating sessions
class MigrationResult {
  final int migrated;
  final int failed;
  final int total;
  final bool success;
  final String? error;

  MigrationResult({
    required this.migrated,
    required this.failed,
    required this.total,
    this.success = true,
    this.error,
  });

  factory MigrationResult.fromJson(Map<String, dynamic> json) {
    return MigrationResult(
      migrated: json['migrated'] as int? ?? 0,
      failed: json['failed'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      success: json['success'] as bool? ?? true,
      error: json['error'] as String?,
    );
  }

  factory MigrationResult.error(String message) {
    return MigrationResult(
      migrated: 0,
      failed: 0,
      total: 0,
      success: false,
      error: message,
    );
  }
}
