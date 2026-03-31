import 'package:flutter/foundation.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';

/// Utility class for building WAV audio files from BLE audio streams
///
/// This class handles:
/// - Buffering audio packets from BLE
/// - Frame assembly from multi-packet frames
/// - Codec-specific decoding (PCM8, PCM16, Opus)
/// - WAV file generation with proper headers
class WavBytesUtil {
  final BleAudioCodec codec;

  List<List<int>> frames = [];
  List<List<int>> rawPackets = [];

  // Opus decoder (lazy initialized if needed)
  SimpleOpusDecoder? _opusDecoder;

  // Frame assembly state
  int _lastPacketIndex = -1;
  int _lastFrameId = -1;
  List<int> _pending = [];
  int _lostFrameCount = 0;

  WavBytesUtil({required this.codec}) {
    debugPrint('[WavBytesUtil] Creating with codec: $codec');

    // Initialize Opus decoder if needed (for Omi BLE audio)
    if (codec == BleAudioCodec.opus) {
      try {
        debugPrint('[WavBytesUtil] Creating Opus decoder...');
        _opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
        debugPrint('[WavBytesUtil] ✅ Opus decoder created successfully');
      } catch (e, stackTrace) {
        debugPrint('[WavBytesUtil] ❌ Failed to create Opus decoder: $e');
        debugPrint('[WavBytesUtil] Stack trace: $stackTrace');
        debugPrint(
          '[WavBytesUtil] This likely means opus_dart.initOpus() was not called in main.dart',
        );
        rethrow;
      }
    }
  }

  /// Store an incoming BLE audio packet
  ///
  /// Packets are assembled into frames. Each packet contains:
  /// - Bytes 0-1: Packet index (little endian)
  /// - Byte 2: Frame ID (internal frame number)
  /// - Bytes 3+: Audio data
  void storeFramePacket(List<int> packet) {
    rawPackets.add(packet);

    if (packet.length < 3) {
      debugPrint('[WavBytesUtil] Invalid packet length: ${packet.length}');
      return;
    }

    final packetIndex = packet[0] + (packet[1] << 8);
    final frameId = packet[2];
    final content = packet.sublist(3);

    // Start of a new frame sequence
    if (_lastPacketIndex == -1 && frameId == 0) {
      _lastPacketIndex = packetIndex;
      _lastFrameId = frameId;
      _pending = List<int>.from(content);
      return;
    }

    if (_lastPacketIndex == -1) return;

    // Start of new frame - ALWAYS accept frameId == 0 as new frame start
    // This handles both fragmented and single-packet frames
    if (frameId == 0) {
      // Save previous pending frame if it exists
      if (_pending.isNotEmpty) {
        frames.add(List<int>.from(_pending));
      }
      _pending = List<int>.from(content);
      _lastFrameId = frameId;
      _lastPacketIndex = packetIndex;
      return;
    }

    // For continuation packets (frameId > 0), check sequence
    if (packetIndex != _lastPacketIndex + 1 || frameId != _lastFrameId + 1) {
      debugPrint(
        '[WavBytesUtil] Lost frame detected (packet: $packetIndex, frame: $frameId)',
      );
      _lastPacketIndex = -1;
      _pending.clear();
      _lostFrameCount++;
      return;
    }

    // Continue current frame
    _pending.addAll(content);
    _lastFrameId = frameId;
    _lastPacketIndex = packetIndex;
  }

  /// Finalize the current pending frame
  /// Call this before building the WAV file to ensure last frame is included
  void finalizeCurrentFrame() {
    if (_pending.isNotEmpty) {
      debugPrint(
        '[WavBytesUtil] Finalizing pending frame (${_pending.length} bytes)',
      );
      frames.add(List<int>.from(_pending));
      _pending.clear();
      _lastPacketIndex = -1;
      _lastFrameId = -1;
    }
  }

  /// Build a WAV file from collected frames
  /// Returns the WAV file bytes
  Uint8List buildWavFile() {
    debugPrint(
      '[WavBytesUtil] Building WAV file from ${frames.length} frames (codec: $codec)',
    );

    // Finalize any pending frame
    finalizeCurrentFrame();

    if (frames.isEmpty) {
      debugPrint('[WavBytesUtil] No frames to build WAV file');
      return Uint8List(0);
    }

    final sampleRate = mapCodecToSampleRate(codec);
    Uint8List pcmData;

    // Decode based on codec
    switch (codec) {
      case BleAudioCodec.pcm8:
        pcmData = _processPcm8();
        break;
      case BleAudioCodec.pcm16:
        pcmData = _processPcm16();
        break;
      case BleAudioCodec.opus:
        pcmData = _processOpus();
        break;
      case BleAudioCodec.mulaw8:
      case BleAudioCodec.mulaw16:
        throw UnimplementedError('mulaw codec not yet supported');
      default:
        throw Exception('Unknown codec: $codec');
    }

    // Build WAV file with header
    final header = _buildWavHeader(pcmData.length, sampleRate);
    final wavBytes = Uint8List.fromList([...header, ...pcmData]);

    debugPrint(
      '[WavBytesUtil] Built WAV file: ${wavBytes.length} bytes, ${frames.length} frames, $sampleRate Hz',
    );
    if (_lostFrameCount > 0) {
      debugPrint('[WavBytesUtil] Lost frames: $_lostFrameCount');
    }

    return wavBytes;
  }

  /// Process PCM8 frames (8-bit, 8kHz)
  Uint8List _processPcm8() {
    final pcmSamples = frames.expand((f) => f).toList();
    return _convertToLittleEndianBytes(pcmSamples);
  }

  /// Process PCM16 frames (16-bit, 16kHz)
  Uint8List _processPcm16() {
    final pcmSamples = frames.expand((f) => f).toList();
    return _convertToLittleEndianBytes(pcmSamples);
  }

  /// Process Opus frames (for Omi BLE audio)
  Uint8List _processOpus() {
    if (_opusDecoder == null) {
      throw StateError('Opus decoder not initialized');
    }

    final decodedSamples = <int>[];

    try {
      for (final frame in frames) {
        final decoded = _opusDecoder!.decode(input: Uint8List.fromList(frame));
        decodedSamples.addAll(decoded);
      }
      debugPrint(
        '[WavBytesUtil] Decoded ${frames.length} Opus frames to ${decodedSamples.length} samples',
      );
    } catch (e, stackTrace) {
      debugPrint('[WavBytesUtil] Opus decoding error: $e\n$stackTrace');
      throw Exception('Opus decoding failed: $e');
    }

    return _convertToLittleEndianBytes(decodedSamples);
  }

  /// Convert PCM samples to little-endian bytes
  Uint8List _convertToLittleEndianBytes(List<int> samples) {
    final byteData = ByteData(2 * samples.length);
    for (var i = 0; i < samples.length; i++) {
      byteData.setInt16(i * 2, samples[i], Endian.little);
    }
    return byteData.buffer.asUint8List();
  }

  /// Build WAV file header (44 bytes)
  Uint8List _buildWavHeader(
    int dataLength,
    int sampleRate, {
    int bitsPerSample = 16,
    int channelCount = 1,
  }) {
    final sampleWidth = bitsPerSample ~/ 8;
    final byteData = ByteData(44);
    final fileSize = dataLength + 36;
    final byteRate = sampleRate * channelCount * sampleWidth;
    final blockAlign = channelCount * sampleWidth;

    // RIFF chunk
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, fileSize, Endian.little);
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'

    // fmt chunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little); // Subchunk1Size
    byteData.setUint16(20, 1, Endian.little); // AudioFormat (1 = PCM)
    byteData.setUint16(22, channelCount, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
    byteData.setUint32(40, dataLength, Endian.little);

    return byteData.buffer.asUint8List();
  }

  /// Clear all buffered audio data
  void clear() {
    frames.clear();
    rawPackets.clear();
    _pending.clear();
    _lastPacketIndex = -1;
    _lastFrameId = -1;
    _lostFrameCount = 0;
    debugPrint('[WavBytesUtil] Cleared all buffers');
  }

  /// Get duration of recorded audio
  Duration get duration {
    if (frames.isEmpty) return Duration.zero;

    final sampleRate = mapCodecToSampleRate(codec);
    final totalSamples = frames.fold<int>(
      0,
      (sum, frame) => sum + frame.length,
    );

    // Approximate calculation (may vary based on codec)
    final seconds = totalSamples / sampleRate;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Check if there are any frames buffered
  bool get hasFrames => frames.isNotEmpty;

  /// Get statistics
  Map<String, dynamic> get stats => {
    'frames': frames.length,
    'rawPackets': rawPackets.length,
    'lostFrames': _lostFrameCount,
    'codec': codec.toString(),
    'duration': duration.toString(),
  };
}
