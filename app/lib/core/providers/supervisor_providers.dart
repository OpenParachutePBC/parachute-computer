import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/supervisor_models.dart';
import '../services/supervisor_service.dart';
import '../services/models_service.dart';
import 'app_state_provider.dart';

part 'supervisor_providers.g.dart';

/// Supervisor service singleton (for server management)
@riverpod
SupervisorService supervisorService(SupervisorServiceRef ref) {
  // Get main server URL and derive supervisor URL (port 3334 instead of 3333)
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final serverUrl = serverUrlAsync.valueOrNull ?? 'http://localhost:3333';
  final supervisorUrl = serverUrl.replaceAll(':3333', ':3334');

  final service = SupervisorService(baseUrl: supervisorUrl);
  ref.onDispose(() => service.dispose());
  return service;
}

/// Models service singleton (for model selection - talks to supervisor)
@riverpod
ModelsService modelsService(ModelsServiceRef ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final serverUrl = serverUrlAsync.valueOrNull ?? 'http://localhost:3333';
  final supervisorUrl = serverUrl.replaceAll(':3333', ':3334');

  final service = ModelsService(baseUrl: supervisorUrl);
  ref.onDispose(() => service.dispose());
  return service;
}

/// Supervisor status provider (auto-refresh every 5s)
@riverpod
class SupervisorStatusNotifier extends _$SupervisorStatusNotifier {
  @override
  Future<SupervisorStatus> build() async {
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
    final service = ref.watch(modelsServiceProvider);
    return service.getModels(showAll: showAll);
  }

  /// Refresh model list from Anthropic API
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(modelsServiceProvider);
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
    ref.invalidate(supervisorStatusNotifierProvider);
  }

  Future<void> stop() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.stopServer();
    });

    ref.invalidate(supervisorStatusNotifierProvider);
  }

  Future<void> restart() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      await service.restartServer();
    });

    ref.invalidate(supervisorStatusNotifierProvider);
  }
}

