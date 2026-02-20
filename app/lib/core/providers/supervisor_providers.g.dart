// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'supervisor_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$supervisorServiceHash() => r'1648cf9759d3816a91ce01353f11a313e1d66708';

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
String _$modelsServiceHash() => r'a68cd334ebab0aba067d4fa563fbf92118e36c17';

/// Models service singleton (for model selection - talks to supervisor)
///
/// Copied from [modelsService].
@ProviderFor(modelsService)
final modelsServiceProvider = AutoDisposeProvider<ModelsService>.internal(
  modelsService,
  name: r'modelsServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$modelsServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ModelsServiceRef = AutoDisposeProviderRef<ModelsService>;
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
String _$availableModelsHash() => r'09bdab6358102040ef88ab3e5fc8f28116e39bb2';

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
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
