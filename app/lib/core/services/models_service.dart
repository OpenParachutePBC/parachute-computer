import 'dart:async';
import 'package:dio/dio.dart';

import '../models/supervisor_models.dart';

class ModelsService {
  ModelsService({required this.baseUrl}) {
    _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: const Duration(seconds: 5)));
  }

  final String baseUrl;
  late final Dio _dio;

  Future<List<ModelInfo>> getModels({bool showAll = false}) async {
    final response =
        await _dio.get('/supervisor/models', queryParameters: {'show_all': showAll});
    final data = response.data;
    return (data['models'] as List).map((m) => ModelInfo.fromJson(m)).toList();
  }

  void dispose() {
    _dio.close();
  }
}
