import 'package:flutter/foundation.dart';

@immutable
class SupervisorStatus {
  const SupervisorStatus({
    required this.supervisorUptimeSeconds,
    required this.supervisorVersion,
    required this.mainServerHealthy,
    required this.mainServerStatus,
    required this.configLoaded,
  });

  final int supervisorUptimeSeconds;
  final String supervisorVersion;
  final bool mainServerHealthy;
  final String mainServerStatus; // "running" | "stopped"
  final bool configLoaded;

  factory SupervisorStatus.fromJson(Map<String, dynamic> json) {
    return SupervisorStatus(
      supervisorUptimeSeconds: json['supervisor_uptime_seconds'] as int,
      supervisorVersion: json['supervisor_version'] as String,
      mainServerHealthy: json['main_server_healthy'] as bool,
      mainServerStatus: json['main_server_status'] as String,
      configLoaded: json['config_loaded'] as bool,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SupervisorStatus &&
          supervisorUptimeSeconds == other.supervisorUptimeSeconds &&
          mainServerHealthy == other.mainServerHealthy &&
          mainServerStatus == other.mainServerStatus;

  @override
  int get hashCode => Object.hash(
      supervisorUptimeSeconds, mainServerHealthy, mainServerStatus);
}

@immutable
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.displayName,
    required this.createdAt,
    required this.family,
    required this.isLatest,
  });

  final String id;
  final String displayName;
  final DateTime createdAt;
  final String family;
  final bool isLatest;

  factory ModelInfo.fromJson(Map<String, dynamic> json) {
    return ModelInfo(
      id: json['id'] as String,
      displayName: json['display_name'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      family: json['family'] as String,
      isLatest: json['is_latest'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelInfo && id == other.id && displayName == other.displayName;

  @override
  int get hashCode => Object.hash(id, displayName);
}
