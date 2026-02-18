// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'supervisor_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$supervisorServiceHash() => r'5670fa4fab4483e1141b43e6a1ed51da1f53df1d';

/// Supervisor service singleton
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
String _$supervisorStatusHash() => r'8a3ced3ea660a2571a21eae78a823c3df922f716';

/// Supervisor status provider (auto-refresh every 5s)
///
/// Copied from [SupervisorStatus].
@ProviderFor(SupervisorStatus)
final supervisorStatusProvider =
    AutoDisposeAsyncNotifierProvider<
      SupervisorStatus,
      SupervisorStatusResponse
    >.internal(
      SupervisorStatus.new,
      name: r'supervisorStatusProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$supervisorStatusHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$SupervisorStatus = AutoDisposeAsyncNotifier<SupervisorStatusResponse>;
String _$availableModelsHash() => r'24b65ef9385bc998cdf64d7af3a07f8156fe86f0';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

abstract class _$AvailableModels
    extends BuildlessAutoDisposeAsyncNotifier<List<ModelInfo>> {
  late final bool showAll;

  FutureOr<List<ModelInfo>> build({bool showAll = false});
}

/// Available models provider (cached, manual refresh)
///
/// Copied from [AvailableModels].
@ProviderFor(AvailableModels)
const availableModelsProvider = AvailableModelsFamily();

/// Available models provider (cached, manual refresh)
///
/// Copied from [AvailableModels].
class AvailableModelsFamily extends Family<AsyncValue<List<ModelInfo>>> {
  /// Available models provider (cached, manual refresh)
  ///
  /// Copied from [AvailableModels].
  const AvailableModelsFamily();

  /// Available models provider (cached, manual refresh)
  ///
  /// Copied from [AvailableModels].
  AvailableModelsProvider call({bool showAll = false}) {
    return AvailableModelsProvider(showAll: showAll);
  }

  @override
  AvailableModelsProvider getProviderOverride(
    covariant AvailableModelsProvider provider,
  ) {
    return call(showAll: provider.showAll);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'availableModelsProvider';
}

/// Available models provider (cached, manual refresh)
///
/// Copied from [AvailableModels].
class AvailableModelsProvider
    extends
        AutoDisposeAsyncNotifierProviderImpl<AvailableModels, List<ModelInfo>> {
  /// Available models provider (cached, manual refresh)
  ///
  /// Copied from [AvailableModels].
  AvailableModelsProvider({bool showAll = false})
    : this._internal(
        () => AvailableModels()..showAll = showAll,
        from: availableModelsProvider,
        name: r'availableModelsProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$availableModelsHash,
        dependencies: AvailableModelsFamily._dependencies,
        allTransitiveDependencies:
            AvailableModelsFamily._allTransitiveDependencies,
        showAll: showAll,
      );

  AvailableModelsProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.showAll,
  }) : super.internal();

  final bool showAll;

  @override
  FutureOr<List<ModelInfo>> runNotifierBuild(
    covariant AvailableModels notifier,
  ) {
    return notifier.build(showAll: showAll);
  }

  @override
  Override overrideWith(AvailableModels Function() create) {
    return ProviderOverride(
      origin: this,
      override: AvailableModelsProvider._internal(
        () => create()..showAll = showAll,
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        showAll: showAll,
      ),
    );
  }

  @override
  AutoDisposeAsyncNotifierProviderElement<AvailableModels, List<ModelInfo>>
  createElement() {
    return _AvailableModelsProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is AvailableModelsProvider && other.showAll == showAll;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, showAll.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin AvailableModelsRef
    on AutoDisposeAsyncNotifierProviderRef<List<ModelInfo>> {
  /// The parameter `showAll` of this provider.
  bool get showAll;
}

class _AvailableModelsProviderElement
    extends
        AutoDisposeAsyncNotifierProviderElement<
          AvailableModels,
          List<ModelInfo>
        >
    with AvailableModelsRef {
  _AvailableModelsProviderElement(super.provider);

  @override
  bool get showAll => (origin as AvailableModelsProvider).showAll;
}

String _$serverControlHash() => r'808988ddb4ca692a53b0f77d5c2402d1c49a271a';

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
String _$modelConfigHash() => r'3690df1119481b704e0da9a7a6fb32040eb9821d';

/// Update default model
///
/// Copied from [ModelConfig].
@ProviderFor(ModelConfig)
final modelConfigProvider =
    AutoDisposeAsyncNotifierProvider<ModelConfig, void>.internal(
      ModelConfig.new,
      name: r'modelConfigProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$modelConfigHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$ModelConfig = AutoDisposeAsyncNotifier<void>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
