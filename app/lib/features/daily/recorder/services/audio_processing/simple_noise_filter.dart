import 'dart:math';

/// Simple audio noise filter using a high-pass filter
///
/// This removes low-frequency noise (fans, AC hum, traffic rumble)
/// that can interfere with VAD (Voice Activity Detection).
///
/// **Not as effective as RNNoise**, but:
/// - No dependencies
/// - Pure Dart implementation
/// - Real-time capable
/// - Removes constant background drone
///
/// For keyboard typing, complex background voices, or music,
/// you'll need full RNNoise (Phase 2).
class SimpleNoiseFilter {
  // High-pass filter state (IIR - Infinite Impulse Response)
  double _prevInput = 0.0;
  double _prevOutput = 0.0;

  /// Cutoff frequency in Hz (default: 80Hz removes rumble/hum)
  final double cutoffFreq;

  /// Sample rate (should match your audio: 16kHz)
  final int sampleRate;

  /// Filter coefficient (calculated from cutoff frequency)
  late final double _alpha;

  SimpleNoiseFilter({this.cutoffFreq = 80.0, this.sampleRate = 16000}) {
    // Calculate alpha coefficient for high-pass filter
    // RC = 1 / (2π × cutoff_freq)
    // α = RC / (RC + dt)
    final rc = 1.0 / (2 * pi * cutoffFreq);
    final dt = 1.0 / sampleRate;
    _alpha = rc / (rc + dt);
  }

  /// Process audio samples through high-pass filter
  ///
  /// Input: 16-bit PCM samples (int16: -32768 to 32767)
  /// Output: Filtered samples (same format)
  ///
  /// This removes frequencies below [cutoffFreq] Hz.
  List<int> process(List<int> samples) {
    if (samples.isEmpty) {
      return samples;
    }

    final filtered = <int>[];

    for (final sample in samples) {
      // Convert to normalized float
      final input = sample.toDouble();

      // High-pass filter formula:
      // y[n] = α × (y[n-1] + x[n] - x[n-1])
      final output = _alpha * (_prevOutput + input - _prevInput);

      // Convert back to int16 with clamping
      final outputInt = output.round().clamp(-32768, 32767);
      filtered.add(outputInt);

      // Update state
      _prevInput = input;
      _prevOutput = output;
    }

    return filtered;
  }

  /// Reset filter state (call when starting new recording)
  void reset() {
    _prevInput = 0.0;
    _prevOutput = 0.0;
  }
}
