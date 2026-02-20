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

  void dispose() {
    _dio.close(); // Close connection pool
  }
}
