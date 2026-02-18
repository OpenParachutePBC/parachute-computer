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

  Future<List<ModelInfo>> getModels({bool showAll = false}) async {
    final response =
        await _dio.get('/supervisor/models', queryParameters: {'show_all': showAll});
    final data = response.data;
    return (data['models'] as List).map((m) => ModelInfo.fromJson(m)).toList();
  }

  Future<void> updateConfig(Map<String, dynamic> values, {bool restart = true}) async {
    await _dio.put('/supervisor/config', data: {'values': values, 'restart': restart});
  }

  void dispose() {
    _dio.close(); // Close connection pool
  }
}
