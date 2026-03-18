import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import './backend_health_provider.dart';

/// Fast-fail / fast-recover override for server reachability.
///
/// Set by API callers:
/// - `false` when a network call fails (fast-fail — don't wait for next health poll)
/// - `true` when a network call succeeds (fast-recover)
/// - `null` to clear the override and defer to the periodic health check
///
/// The periodic health check resets this to null on each emission so it
/// doesn't go stale (see listener in [isServerAvailableProvider]).
final serverReachableOverrideProvider = StateProvider<bool?>((ref) => null);

/// Simple provider: is server available?
///
/// Checks the fast-fail override first, then falls back to the periodic health
/// check stream. Returns false for offline, error, or loading states (safe
/// default for gating API calls).
///
/// Usage:
/// ```dart
/// final available = ref.watch(isServerAvailableProvider);
/// if (!available) return null; // Don't make API call
/// ```
final isServerAvailableProvider = Provider<bool>((ref) {
  // When the periodic health check fires, clear the override so it doesn't
  // go stale. The health check is the ground truth; the override is just a
  // fast bridge between polls.
  ref.listen(periodicServerHealthProvider, (_, __) {
    ref.read(serverReachableOverrideProvider.notifier).state = null;
  });

  // Fast-fail / fast-recover override takes precedence
  final override = ref.watch(serverReachableOverrideProvider);
  if (override != null) return override;

  // Fall back to periodic health check
  final healthAsync = ref.watch(periodicServerHealthProvider);

  return healthAsync.when(
    data: (health) => health != null && health.isHealthy,
    loading: () => false, // Assume offline while checking
    error: (err, st) {
      debugPrint('[ConnectivityProvider] Error: $err');
      return false; // Assume offline on error
    },
  );
});
