import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/supervisor_models.dart';
import '../services/supervisor_service.dart';

part 'supervisor_providers.g.dart';

/// Supervisor service singleton
@riverpod
SupervisorService supervisorService(SupervisorServiceRef ref) {
  final service = SupervisorService(baseUrl: 'http://localhost:3334');
  ref.onDispose(() => service.dispose());
  return service;
}

/// Supervisor status provider (auto-refresh every 5s)
@riverpod
class SupervisorStatus extends _$SupervisorStatus {
  @override
  Future<SupervisorStatusResponse> build() async {
    // Auto-refresh every 5 seconds
    final timer = ref.keepAlive();
    Future.delayed(const Duration(seconds: 5), () => timer.close());

    final service = ref.watch(supervisorServiceProvider);
    return service.getStatus();
  }

  /// Manual refresh
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      return service.getStatus();
    });
  }
}

/// Available models provider (cached, manual refresh)
@riverpod
class AvailableModels extends _$AvailableModels {
  @override
  Future<List<ModelInfo>> build({bool showAll = false}) async {
    final service = ref.watch(supervisorServiceProvider);
    return service.getModels(showAll: showAll);
  }

  /// Refresh model list from Anthropic API
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      return service.getModels(showAll: false);
    });
  }
}

/// Server control actions
@riverpod
class ServerControl extends _$ServerControl {
  @override
  Future<void> build() async {
    // No initial state
  }

  Future<void> start() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.startServer();
    });

    // Refresh status after action
    ref.invalidate(supervisorStatusProvider);
  }

  Future<void> stop() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.stopServer();
    });

    ref.invalidate(supervisorStatusProvider);
  }

  Future<void> restart() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.restartServer();
    });

    ref.invalidate(supervisorStatusProvider);
  }
}

/// Update default model
@riverpod
class ModelConfig extends _$ModelConfig {
  @override
  Future<void> build() async {
    // No initial state
  }

  Future<void> updateDefaultModel(String modelId, {bool restart = true}) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.updateConfig({'default_model': modelId}, restart: restart);
    });

    // Refresh status to reflect new config
    ref.invalidate(supervisorStatusProvider);
  }
}
