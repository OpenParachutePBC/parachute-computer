import 'dart:async';

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

/// Cached supervisor server config (reads default_model etc).
///
/// Wraps GET /supervisor/config. Exposes [setModel] to persist
/// a new default_model via PUT /supervisor/config.
///
/// keepAlive: true — app-level config; must survive widget disposal so
/// chat_message_providers can always read it via ref.read.
@Riverpod(keepAlive: true)
class SupervisorConfig extends _$SupervisorConfig {
  @override
  Future<Map<String, dynamic>> build() async {
    final service = ref.watch(supervisorServiceProvider);
    return service.getConfig();
  }

  /// Persist a model change to config.yaml, with rollback on failure.
  Future<void> setModel(String modelId) async {
    final previousState = state;
    // Optimistic update — show new model immediately in the picker
    state = AsyncData({...?state.valueOrNull, 'default_model': modelId});
    try {
      final service = ref.read(supervisorServiceProvider);
      await service.updateConfig({'default_model': modelId});
    } catch (_) {
      state = previousState;
      rethrow;
    }
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

/// Docker status provider.
///
/// Polls supervisor every 30s in steady state.
/// When Docker is starting, polls every 3s until ready or timeout.
/// keepAlive: true — chat screen needs this even when settings tab disposes.
@Riverpod(keepAlive: true)
class DockerStatusNotifier extends _$DockerStatusNotifier {
  Timer? _pollTimer;

  @override
  Future<DockerStatus> build() async {
    ref.onDispose(() => _pollTimer?.cancel());

    // Start steady-state polling (30s)
    _startPolling(const Duration(seconds: 30));

    final service = ref.watch(supervisorServiceProvider);
    return service.getDockerStatus();
  }

  void _startPolling(Duration interval) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => refresh());
  }

  /// Manual refresh (also called by polling timer).
  Future<void> refresh() async {
    state = await AsyncValue.guard(() async {
      final service = ref.read(supervisorServiceProvider);
      return service.getDockerStatus();
    });
  }

  /// Start Docker and poll for readiness.
  ///
  /// Returns true if Docker became ready, false on failure/timeout.
  /// Switches to fast polling (3s) during startup, reverts to 30s after.
  Future<bool> startDocker() async {
    final service = ref.read(supervisorServiceProvider);

    // Switch to fast polling while starting
    _startPolling(const Duration(seconds: 3));

    try {
      final success = await service.startDocker();
      // Refresh immediately after start completes
      await refresh();
      return success;
    } catch (_) {
      return false;
    } finally {
      // Revert to steady-state polling
      _startPolling(const Duration(seconds: 30));
    }
  }

  /// Stop Docker runtime.
  Future<bool> stopDocker() async {
    final service = ref.read(supervisorServiceProvider);
    try {
      final success = await service.stopDocker();
      await refresh();
      return success;
    } catch (_) {
      return false;
    }
  }
}

