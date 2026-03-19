// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'supervisor_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$supervisorServiceHash() => r'56e085fd206f965c92a995c51696ba878424339d';

/// Supervisor service singleton (for server management)
///
/// Copied from [supervisorService].
@ProviderFor(supervisorService)
final supervisorServiceProvider =
    AutoDisposeProvider<SupervisorService>.internal(
      supervisorService,
      name: r'supervisorServiceProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$supervisorServiceHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SupervisorServiceRef = AutoDisposeProviderRef<SupervisorService>;
String _$supervisorStatusNotifierHash() =>
    r'afb99dbb62b19829786f04f77cd2243902539acc';

/// Supervisor status provider (auto-refresh every 5s)
///
/// Copied from [SupervisorStatusNotifier].
@ProviderFor(SupervisorStatusNotifier)
final supervisorStatusNotifierProvider =
    AutoDisposeAsyncNotifierProvider<
      SupervisorStatusNotifier,
      SupervisorStatus
    >.internal(
      SupervisorStatusNotifier.new,
      name: r'supervisorStatusNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$supervisorStatusNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SupervisorStatusNotifier = AutoDisposeAsyncNotifier<SupervisorStatus>;
String _$supervisorConfigHash() => r'be7c81b1eaf54aa792510407dafcf677d986f8f2';

/// Cached supervisor server config (reads default_model etc).
///
/// Wraps GET /supervisor/config. Exposes [setModel] to persist
/// a new default_model via PUT /supervisor/config.
///
/// keepAlive: true — app-level config; must survive widget disposal so
/// chat_message_providers can always read it via ref.read.
///
/// Copied from [SupervisorConfig].
@ProviderFor(SupervisorConfig)
final supervisorConfigProvider =
    AsyncNotifierProvider<SupervisorConfig, Map<String, dynamic>>.internal(
      SupervisorConfig.new,
      name: r'supervisorConfigProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$supervisorConfigHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SupervisorConfig = AsyncNotifier<Map<String, dynamic>>;
String _$serverControlHash() => r'3453c7ccbdfb30616a2cf071e269b853929901b9';

/// Server control actions
///
/// Copied from [ServerControl].
@ProviderFor(ServerControl)
final serverControlProvider =
    AutoDisposeAsyncNotifierProvider<ServerControl, void>.internal(
      ServerControl.new,
      name: r'serverControlProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$serverControlHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ServerControl = AutoDisposeAsyncNotifier<void>;
String _$dockerStatusNotifierHash() =>
    r'a028cef3ac72d89f598d953cf731c2471664c688';

/// Docker status provider.
///
/// Polls supervisor every 30s in steady state.
/// When Docker is starting, polls every 3s until ready or timeout.
/// keepAlive: true — chat screen needs this even when settings tab disposes.
///
/// Copied from [DockerStatusNotifier].
@ProviderFor(DockerStatusNotifier)
final dockerStatusNotifierProvider =
    AsyncNotifierProvider<DockerStatusNotifier, DockerStatus>.internal(
      DockerStatusNotifier.new,
      name: r'dockerStatusNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$dockerStatusNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$DockerStatusNotifier = AsyncNotifier<DockerStatus>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
