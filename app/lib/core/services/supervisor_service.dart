import 'dart:async';
import 'package:dio/dio.dart';

import '../models/supervisor_models.dart';

class SupervisorService {
  SupervisorService({required this.baseUrl}) {
    _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 5)));
  }

  final String baseUrl;
  late final Dio _dio;

  Future<SupervisorStatus> getStatus() async {
    final response = await _dio.get('/supervisor/status');
    return SupervisorStatus.fromJson(response.data);
  }

  Future<void> startServer() async {
    await _dio.post('/supervisor/server/start');
  }

  Future<void> stopServer() async {
    await _dio.post('/supervisor/server/stop');
  }

  Future<void> restartServer() async {
    await _dio.post('/supervisor/server/restart');
  }

  /// Read current server config (secrets redacted by server).
  Future<Map<String, dynamic>> getConfig() async {
    final response = await _dio.get('/supervisor/config');
    return (response.data['config'] as Map<String, dynamic>?) ?? {};
  }

  /// Update config values. Does NOT restart the server.
  Future<void> updateConfig(Map<String, dynamic> values) async {
    await _dio.put('/supervisor/config', data: {'values': values, 'restart': false});
  }

  // === Docker Management ===

  /// Get Docker daemon status, detected runtimes, and sandbox readiness.
  Future<DockerStatus> getDockerStatus() async {
    try {
      final response = await _dio.get('/supervisor/docker/status');
      return DockerStatus.fromJson(response.data);
    } catch (_) {
      return DockerStatus.unknown();
    }
  }

  /// Start the preferred Docker runtime. Blocks until ready (up to 45s).
  Future<bool> startDocker() async {
    final response = await _dio.post(
      '/supervisor/docker/start',
      options: Options(receiveTimeout: const Duration(seconds: 60)),
    );
    return (response.data['success'] as bool?) ?? false;
  }

  /// Stop the running Docker runtime.
  Future<bool> stopDocker() async {
    final response = await _dio.post('/supervisor/docker/stop');
    return (response.data['success'] as bool?) ?? false;
  }

  void dispose() {
    _dio.close(); // Close connection pool
  }
}
