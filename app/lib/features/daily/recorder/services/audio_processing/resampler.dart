/// Audio resampler for converting between 16kHz and 48kHz
///
/// This is a direct port of RichardTate's resampling implementation.
/// Source: https://github.com/lucianHymer/richardtate
/// File: server/internal/transcription/resample.go
///
/// Simple 3x resampler for 16kHz ↔ 48kHz conversion.
/// Since 48000 / 16000 = 3 (perfect integer ratio), we can use
/// simple decimation/interpolation without complex filtering.
class Resampler {
  /// Upsample 16kHz audio to 48kHz using linear interpolation
  ///
  /// Input: 16-bit PCM samples at 16kHz
  /// Output: 16-bit PCM samples at 48kHz (3x length)
  ///
  /// This matches RichardTate's Upsample16to48 exactly.
  List<int> upsample16to48(List<int> input) {
    if (input.isEmpty) {
      return [];
    }

    // Output will be 3x the length
    final output = List<int>.filled(input.length * 3, 0);

    for (var i = 0; i < input.length; i++) {
      final baseIdx = i * 3;

      if (i < input.length - 1) {
        // Linear interpolation between current and next sample
        final curr = input[i];
        final next = input[i + 1];
        final diff = next - curr;

        output[baseIdx] = curr;
        output[baseIdx + 1] = curr + diff ~/ 3;
        output[baseIdx + 2] = curr + (2 * diff) ~/ 3;
      } else {
        // Last sample: just repeat
        output[baseIdx] = input[i];
        output[baseIdx + 1] = input[i];
        output[baseIdx + 2] = input[i];
      }
    }

    return output;
  }

  /// Downsample 48kHz audio to 16kHz using simple decimation
  ///
  /// Input: 16-bit PCM samples at 48kHz
  /// Output: 16-bit PCM samples at 16kHz (1/3 length)
  ///
  /// This matches RichardTate's Downsample48to16 exactly.
  List<int> downsample48to16(List<int> input) {
    if (input.isEmpty) {
      return [];
    }

    // Output will be 1/3 the length
    final outputLen = input.length ~/ 3;
    final output = List<int>.filled(outputLen, 0);

    // Take every 3rd sample (with simple averaging for anti-aliasing)
    for (var i = 0; i < outputLen; i++) {
      final idx = i * 3;

      // Average the 3 samples to prevent aliasing
      if (idx + 2 < input.length) {
        final sum = input[idx] + input[idx + 1] + input[idx + 2];
        output[i] = sum ~/ 3;
      } else {
        output[i] = input[idx];
      }
    }

    return output;
  }

  /// Upsample 16kHz float audio to 48kHz
  ///
  /// Used when RNNoise needs float32 input.
  /// Input: float32 samples at 16kHz (range: -1.0 to 1.0)
  /// Output: float32 samples at 48kHz (3x length)
  List<double> upsample16to48Float(List<double> input) {
    if (input.isEmpty) {
      return [];
    }

    final output = List<double>.filled(input.length * 3, 0.0);

    for (var i = 0; i < input.length; i++) {
      final baseIdx = i * 3;

      if (i < input.length - 1) {
        final curr = input[i];
        final next = input[i + 1];
        final diff = next - curr;

        output[baseIdx] = curr;
        output[baseIdx + 1] = curr + diff / 3;
        output[baseIdx + 2] = curr + (2 * diff) / 3;
      } else {
        output[baseIdx] = input[i];
        output[baseIdx + 1] = input[i];
        output[baseIdx + 2] = input[i];
      }
    }

    return output;
  }

  /// Downsample 48kHz float audio to 16kHz
  ///
  /// Input: float32 samples at 48kHz
  /// Output: float32 samples at 16kHz (1/3 length)
  List<double> downsample48to16Float(List<double> input) {
    if (input.isEmpty) {
      return [];
    }

    final outputLen = input.length ~/ 3;
    final output = List<double>.filled(outputLen, 0.0);

    for (var i = 0; i < outputLen; i++) {
      final idx = i * 3;

      if (idx + 2 < input.length) {
        final sum = input[idx] + input[idx + 1] + input[idx + 2];
        output[i] = sum / 3;
      } else {
        output[i] = input[idx];
      }
    }

    return output;
  }
}
