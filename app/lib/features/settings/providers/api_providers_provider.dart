import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/providers/chat_session_providers.dart';
import '../../chat/services/chat_service.dart';

/// State for the API providers list + active provider.
class ApiProvidersState {
  final String? active;
  final List<ApiProviderConfig> providers;

  const ApiProvidersState({this.active, this.providers = const []});
}

/// Notifier that fetches and manages API provider configs from the server.
class ApiProvidersNotifier extends AsyncNotifier<ApiProvidersState> {
  @override
  Future<ApiProvidersState> build() async {
    try {
      final service = ref.read(chatServiceProvider);
      final result = await service.fetchProviders();
      return ApiProvidersState(
        active: result.active,
        providers: result.providers,
      );
    } catch (e) {
      debugPrint('[ApiProvidersNotifier] Error loading providers: $e');
      return const ApiProvidersState();
    }
  }

  /// Add or update a provider, then refresh.
  Future<void> addProvider({
    required String name,
    required String providerBaseUrl,
    required String apiKey,
    String? label,
    String? defaultModel,
  }) async {
    final service = ref.read(chatServiceProvider);
    await service.addProvider(
      name: name,
      providerBaseUrl: providerBaseUrl,
      apiKey: apiKey,
      label: label,
      defaultModel: defaultModel,
    );
    ref.invalidateSelf();
  }

  /// Remove a provider, then refresh.
  Future<void> removeProvider(String name) async {
    final service = ref.read(chatServiceProvider);
    await service.removeProvider(name);
    ref.invalidateSelf();
  }

  /// Switch the active provider (null = Anthropic default).
  Future<void> setActive(String? providerName) async {
    // Optimistic update
    final previousState = state;
    if (state.hasValue) {
      final current = state.value!;
      state = AsyncData(ApiProvidersState(
        active: providerName,
        providers: current.providers,
      ));
    }

    try {
      final service = ref.read(chatServiceProvider);
      await service.setActiveProvider(providerName);
      ref.invalidateSelf();
    } catch (_) {
      state = previousState;
      rethrow;
    }
  }
}

final apiProvidersProvider =
    AsyncNotifierProvider<ApiProvidersNotifier, ApiProvidersState>(
  ApiProvidersNotifier.new,
);
