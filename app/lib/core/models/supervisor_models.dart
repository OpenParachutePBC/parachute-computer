import 'package:flutter/foundation.dart';

@immutable
class SupervisorStatus {
  const SupervisorStatus({
    required this.supervisorUptimeSeconds,
    required this.supervisorVersion,
    required this.mainServerHealthy,
    required this.mainServerStatus,
    required this.configLoaded,
    this.mainServerUptimeSeconds,
    this.mainServerVersion,
    this.mainServerPort,
  });

  final int supervisorUptimeSeconds;
  final String supervisorVersion;
  final bool mainServerHealthy;
  final String mainServerStatus; // "running" | "stopped"
  final bool configLoaded;
  final int? mainServerUptimeSeconds;
  final String? mainServerVersion;
  final int? mainServerPort;

  factory SupervisorStatus.fromJson(Map<String, dynamic> json) {
    return SupervisorStatus(
      supervisorUptimeSeconds: json['supervisor_uptime_seconds'] as int,
      supervisorVersion: json['supervisor_version'] as String,
      mainServerHealthy: json['main_server_healthy'] as bool,
      mainServerStatus: json['main_server_status'] as String,
      configLoaded: json['config_loaded'] as bool,
      mainServerUptimeSeconds: json['main_server_uptime_seconds'] as int?,
      mainServerVersion: json['main_server_version'] as String?,
      mainServerPort: json['main_server_port'] as int?,
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

@immutable
class DockerStatus {
  const DockerStatus({
    required this.daemonRunning,
    this.runtime,
    this.runtimeDisplay,
    this.detectedRuntimes = const [],
    this.imageExists = false,
    this.autoStartEnabled = false,
  });

  final bool daemonRunning;
  final String? runtime; // "orbstack", "colima", etc.
  final String? runtimeDisplay; // "OrbStack", "Colima", etc.
  final List<String> detectedRuntimes;
  final bool imageExists;
  final bool autoStartEnabled;

  /// Whether any Docker runtime is installed (even if not running).
  bool get hasRuntime => detectedRuntimes.isNotEmpty;

  /// Whether everything is ready for sandboxed execution.
  bool get isReady => daemonRunning && imageExists;

  factory DockerStatus.fromJson(Map<String, dynamic> json) {
    return DockerStatus(
      daemonRunning: json['daemon_running'] as bool? ?? false,
      runtime: json['runtime'] as String?,
      runtimeDisplay: json['runtime_display'] as String?,
      detectedRuntimes: (json['detected_runtimes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      imageExists: json['image_exists'] as bool? ?? false,
      autoStartEnabled: json['auto_start_enabled'] as bool? ?? false,
    );
  }

  /// Fallback for when supervisor is unreachable.
  factory DockerStatus.unknown() {
    return const DockerStatus(daemonRunning: false);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DockerStatus &&
          daemonRunning == other.daemonRunning &&
          runtime == other.runtime &&
          imageExists == other.imageExists;

  @override
  int get hashCode => Object.hash(daemonRunning, runtime, imageExists);
}
