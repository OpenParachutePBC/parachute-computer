import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';

/// Flutter service for Parakeet ASR via sherpa-onnx (Android/cross-platform)
///
/// Uses Parakeet v3 INT8 ONNX models for fast, offline transcription.
/// Supports 25 European languages with automatic language detection.
///
/// This is a singleton to ensure pre-initialization at app startup benefits
/// all transcription requests.
class SherpaOnnxService {
  // Singleton instance
  static final SherpaOnnxService _instance = SherpaOnnxService._internal();

  factory SherpaOnnxService() => _instance;

  SherpaOnnxService._internal();

  sherpa.OfflineRecognizer? _recognizer;
  bool _isInitialized = false;
  bool _isInitializing = false;
  String _modelPath = '';

  bool get isInitialized => _isInitialized;
  bool get isSupported =>
      true; // sherpa-onnx supports all platforms (Android, iOS, macOS, etc.)

  /// Check if models are already downloaded and ready for initialization
  Future<bool> get hasModelsDownloaded async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');
      final encoderFile = File(path.join(modelDir, 'encoder.int8.onnx'));
      final tokensFile = File(path.join(modelDir, 'tokens.txt'));

      if (!await encoderFile.exists() || !await tokensFile.exists()) {
        return false;
      }

      final encoderSize = await encoderFile.length();
      final tokensSize = await tokensFile.length();

      return encoderSize > 100 * 1024 * 1024 && tokensSize > 1000;
    } catch (e) {
      return false;
    }
  }

  /// Pre-initialize if models are already downloaded
  /// This should be called at app startup to avoid UI freeze during first recording
  Future<void> preInitializeIfReady() async {
    if (_isInitialized || _isInitializing) return;

    final hasModels = await hasModelsDownloaded;
    if (!hasModels) {
      debugPrint('[SherpaOnnxService] Models not downloaded, skipping pre-init');
      return;
    }

    debugPrint('[SherpaOnnxService] Pre-initializing (models found)...');
    try {
      await initialize();
      debugPrint('[SherpaOnnxService] Pre-initialization complete');
    } catch (e) {
      debugPrint('[SherpaOnnxService] Pre-initialization failed: $e');
    }
  }

  /// Initialize Parakeet v3 models
  ///
  /// Downloads models from app assets to local storage if needed.
  /// First run may take time to copy assets (~640MB).
  ///
  /// [onProgress] - Optional callback for download/extraction progress (0.0-1.0)
  /// [onStatus] - Optional callback for status messages
  Future<void> initialize({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    if (_isInitialized) {
      debugPrint('[SherpaOnnxService] Already initialized');
      onProgress?.call(1.0);
      onStatus?.call('Ready');
      return;
    }

    // Prevent multiple simultaneous initializations
    if (_isInitializing) {
      debugPrint(
        '[SherpaOnnxService] Initialization already in progress, waiting...',
      );
      onStatus?.call('Initialization in progress...');
      // Wait for the ongoing initialization to complete
      while (_isInitializing && !_isInitialized) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (_isInitialized) {
        onProgress?.call(1.0);
        onStatus?.call('Ready');
        return;
      }
      // If still not initialized after waiting, throw error
      throw StateError('Initialization failed');
    }

    _isInitializing = true;
    try {
      debugPrint('[SherpaOnnxService] Initializing Parakeet v3 INT8...');
      onStatus?.call('Initializing Parakeet v3...');

      // Copy models from assets to local storage (one-time operation)
      final modelDir = await _ensureModelsInLocalStorage(
        onProgress: onProgress,
        onStatus: onStatus,
      );
      _modelPath = modelDir;

      onStatus?.call('Configuring model...');
      onProgress?.call(0.9);

      // Configure Parakeet TDT model (Transducer)
      final modelConfig = sherpa.OfflineTransducerModelConfig(
        encoder: path.join(modelDir, 'encoder.int8.onnx'),
        decoder: path.join(modelDir, 'decoder.int8.onnx'),
        joiner: path.join(modelDir, 'joiner.int8.onnx'),
      );

      // Optimize thread count based on device capabilities
      // Most modern Android devices have 6-8 cores, use more threads for faster transcription
      final numThreads = Platform.numberOfProcessors;
      final optimalThreads = (numThreads * 0.75).ceil().clamp(4, 8);

      debugPrint(
        '[SherpaOnnxService] Device has $numThreads cores, using $optimalThreads threads',
      );

      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: modelConfig,
          tokens: path.join(modelDir, 'tokens.txt'),
          numThreads: optimalThreads,
          debug: kDebugMode,
          modelType:
              'nemo_transducer', // Use NeMo-specific type for Parakeet models
        ),
      );

      // Initialize sherpa-onnx native library (first time only)
      debugPrint('[SherpaOnnxService] Initializing native bindings...');
      onStatus?.call('Initializing native bindings...');
      sherpa.initBindings();

      debugPrint('[SherpaOnnxService] Creating recognizer...');
      onStatus?.call('Creating recognizer...');
      _recognizer = sherpa.OfflineRecognizer(config);

      _isInitialized = true;
      onProgress?.call(1.0);
      onStatus?.call('Ready');
      debugPrint('[SherpaOnnxService] ✅ Initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('[SherpaOnnxService] ❌ Initialization failed: $e');
      debugPrint('[SherpaOnnxService] Stack trace: $stackTrace');
      onStatus?.call('Initialization failed: $e');
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Download and extract model archive from GitHub if not already cached
  ///
  /// Returns the directory path where models are stored.
  Future<String> _ensureModelsInLocalStorage({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');
    final modelDirFile = Directory(modelDir);

    // Check if models already exist and are valid
    final encoderFile = File(path.join(modelDir, 'encoder.int8.onnx'));
    final tokensFile = File(path.join(modelDir, 'tokens.txt'));

    if (await encoderFile.exists() && await tokensFile.exists()) {
      // Verify the files are not empty
      final encoderSize = await encoderFile.length();
      final tokensSize = await tokensFile.length();

      if (encoderSize > 100 * 1024 * 1024 && tokensSize > 1000) {
        debugPrint('[SherpaOnnxService] Valid models found');
        return modelDir;
      }

      // Models are corrupted, delete and re-download
      debugPrint(
        '[SherpaOnnxService] Corrupted models detected, cleaning up...',
      );
      if (await modelDirFile.exists()) {
        await modelDirFile.delete(recursive: true);
      }
    }

    debugPrint(
      '[SherpaOnnxService] Downloading Parakeet v3 archive (~465 MB)...',
    );
    onStatus?.call('Downloading Parakeet v3 models...');
    await modelDirFile.create(recursive: true);

    // Download tar.bz2 archive from GitHub
    const archiveUrl =
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2';
    final archivePath = path.join(
      appDir.path,
      'models',
      'parakeet-v3-int8.tar.bz2',
    );

    try {
      debugPrint('[SherpaOnnxService] Downloading from GitHub...');

      // Stream download with progress tracking
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(archiveUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}',
        );
      }

      final totalBytes = response.contentLength ?? 465 * 1024 * 1024; // ~465MB
      int receivedBytes = 0;

      final archiveFile = File(archivePath);
      final sink = archiveFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        // Report download progress (0.0 - 0.7 of total)
        final downloadProgress = receivedBytes / totalBytes * 0.7;
        onProgress?.call(downloadProgress);

        // Update status every 50MB to reduce log spam
        if (receivedBytes % (50 * 1024 * 1024) < chunk.length) {
          final receivedMB = (receivedBytes / (1024 * 1024)).toStringAsFixed(0);
          final totalMB = (totalBytes / (1024 * 1024)).toStringAsFixed(0);
          final percent = ((receivedBytes / totalBytes) * 100).toStringAsFixed(
            0,
          );
          onStatus?.call(
            'Downloading models: $percent% ($receivedMB/$totalMB MB)',
          );
        }
      }

      await sink.flush(); // Ensure all data is written
      await sink.close();
      client.close();

      // Validate download size
      final downloadedFile = File(archivePath);
      final actualSize = await downloadedFile.length();
      final sizeMB = (actualSize / (1024 * 1024)).toStringAsFixed(1);

      debugPrint('[SherpaOnnxService] ✅ Downloaded ($sizeMB MB)');

      // Verify we got all the data
      if (actualSize != receivedBytes) {
        throw Exception(
          'Download incomplete: expected $receivedBytes bytes, got $actualSize bytes',
        );
      }

      // Basic validation - file should be at least 400MB
      if (actualSize < 400 * 1024 * 1024) {
        throw Exception(
          'Downloaded file too small: $sizeMB MB (expected ~465 MB)',
        );
      }

      // Extract tar.bz2 archive in compute isolate to avoid UI freeze
      debugPrint('[SherpaOnnxService] Extracting archive...');
      onStatus?.call('Extracting models (this may take 1-2 minutes)...');
      onProgress?.call(0.75);

      await compute(_extractArchive, {
        'archivePath': archivePath,
        'modelDir': modelDir,
      });

      // Extraction complete
      debugPrint('[SherpaOnnxService] ✅ Extraction complete');
      onStatus?.call('Finalizing models...');
      onProgress?.call(0.85);

      // Clean up archive file
      await File(archivePath).delete();
      debugPrint('[SherpaOnnxService] ✅ Models ready');
      onStatus?.call('Models ready');

      return modelDir;
    } catch (e) {
      debugPrint('[SherpaOnnxService] ❌ Download/extract failed: $e');
      onStatus?.call('Download failed: $e');
      // Clean up on failure
      if (await File(archivePath).exists()) {
        await File(archivePath).delete();
      }
      rethrow;
    }
  }

  /// Extract tar.bz2 archive in separate isolate to avoid UI freeze
  static Future<void> _extractArchive(Map<String, String> params) async {
    final archivePath = params['archivePath']!;
    final modelDir = params['modelDir']!;

    // Read archive file
    debugPrint('[SherpaOnnxService] Reading archive...');
    final archiveBytes = await File(archivePath).readAsBytes();

    // Decompress bz2 (this takes most of the time)
    debugPrint('[SherpaOnnxService] Decompressing BZip2...');
    final decompressed = BZip2Decoder().decodeBytes(archiveBytes);

    // Extract tar
    debugPrint('[SherpaOnnxService] Extracting TAR archive...');
    final archive = TarDecoder().decodeBytes(decompressed);

    int extractedCount = 0;
    const targetFiles = [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ];

    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        // Extract files from sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/ directory
        final basename = path.basename(filename);
        if (targetFiles.contains(basename)) {
          final outputPath = path.join(modelDir, basename);
          final outputFile = File(outputPath);
          await outputFile.create(recursive: true);
          await outputFile.writeAsBytes(file.content as List<int>);
          final sizeMB = (file.content.length / (1024 * 1024)).toStringAsFixed(
            1,
          );
          extractedCount++;
          debugPrint(
            '[SherpaOnnxService] ✅ Extracted $basename ($sizeMB MB) [$extractedCount/${targetFiles.length}]',
          );
        }
      }
    }

    debugPrint('[SherpaOnnxService] ✅ Extraction complete: $extractedCount files');
  }

  // Chunking configuration
  static const int _sampleRate = 16000;
  static const int _chunkDurationSeconds = 30; // 30 second chunks
  static const int _overlapSeconds = 2; // 2 second overlap to avoid cutting words
  static const int _samplesPerChunk = _sampleRate * _chunkDurationSeconds;
  static const int _overlapSamples = _sampleRate * _overlapSeconds;

  /// Transcribe audio file
  ///
  /// [audioPath] - Absolute path to WAV file (16kHz mono PCM16)
  /// [onProgress] - Optional callback for progress updates (0.0-1.0)
  ///
  /// Returns transcribed text with automatic language detection.
  /// For long audio files, processes in chunks to avoid OOM.
  Future<TranscriptionResult> transcribeAudio(
    String audioPath, {
    Function(double progress)? onProgress,
  }) async {
    if (!_isInitialized) {
      throw StateError('SherpaOnnx not initialized. Call initialize() first.');
    }

    if (_recognizer == null) {
      throw StateError('Recognizer is null after initialization');
    }

    // Validate file exists
    final file = File(audioPath);
    if (!await file.exists()) {
      throw ArgumentError('Audio file not found: $audioPath');
    }

    try {
      debugPrint('[SherpaOnnxService] Transcribing: $audioPath');
      final startTime = DateTime.now();

      // Get file size to determine if chunking is needed
      final fileSize = await file.length();
      final estimatedSamples = (fileSize - 44) ~/ 2; // WAV header is 44 bytes, 2 bytes per sample
      final estimatedDurationSec = estimatedSamples / _sampleRate;

      debugPrint('[SherpaOnnxService] Audio duration: ${estimatedDurationSec.toStringAsFixed(1)}s, samples: $estimatedSamples');

      String fullText;
      List<String> allTokens = [];
      List<double> allTimestamps = [];

      if (estimatedSamples <= _samplesPerChunk * 1.5) {
        // Short audio - process in one go (up to ~45 seconds)
        debugPrint('[SherpaOnnxService] Short audio, processing in one chunk');
        onProgress?.call(0.1); // Start progress
        final result = await _transcribeChunk(audioPath, 0, estimatedSamples);
        fullText = result.text;
        allTokens = result.tokens ?? [];
        allTimestamps = result.timestamps ?? [];
        onProgress?.call(0.9); // Near complete
      } else {
        // Long audio - process in chunks with overlap
        debugPrint('[SherpaOnnxService] Long audio, processing in ${(_samplesPerChunk / _sampleRate).toInt()}s chunks');
        final results = await _transcribeInChunks(
          audioPath,
          estimatedSamples,
          onProgress: onProgress,
        );
        fullText = results.map((r) => r.text).join(' ').trim();
        // Note: tokens/timestamps from chunked processing would need offset adjustment
        // For now, we don't merge them for chunked audio
      }

      final duration = DateTime.now().difference(startTime);

      debugPrint(
        '[SherpaOnnxService] ✅ Transcribed in ${duration.inMilliseconds}ms: "${fullText.substring(0, fullText.length.clamp(0, 100))}..."',
      );

      return TranscriptionResult(
        text: fullText,
        language: 'auto', // Parakeet auto-detects language
        duration: duration,
        tokens: allTokens.isNotEmpty ? allTokens : null,
        timestamps: allTimestamps.isNotEmpty ? allTimestamps : null,
      );
    } catch (e, stackTrace) {
      debugPrint('[SherpaOnnxService] ❌ Transcription failed: $e');
      debugPrint('[SherpaOnnxService] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Transcribe audio in chunks to avoid OOM on long recordings
  Future<List<TranscriptionResult>> _transcribeInChunks(
    String audioPath,
    int totalSamples, {
    Function(double progress)? onProgress,
  }) async {
    final results = <TranscriptionResult>[];
    int chunkStart = 0;
    int chunkIndex = 0;

    // Calculate total number of chunks for progress reporting
    final effectiveChunkSize = _samplesPerChunk - _overlapSamples;
    final totalChunks = ((totalSamples - _overlapSamples) / effectiveChunkSize).ceil();
    debugPrint('[SherpaOnnxService] Estimated $totalChunks chunks to process');

    onProgress?.call(0.05); // Starting

    while (chunkStart < totalSamples) {
      // Calculate chunk bounds
      int chunkEnd = (chunkStart + _samplesPerChunk).clamp(0, totalSamples);

      debugPrint('[SherpaOnnxService] Processing chunk ${chunkIndex + 1}/$totalChunks: samples $chunkStart-$chunkEnd');

      // Transcribe this chunk
      final result = await _transcribeChunk(audioPath, chunkStart, chunkEnd);

      if (result.text.isNotEmpty) {
        results.add(result);
        debugPrint('[SherpaOnnxService] Chunk ${chunkIndex + 1} result: "${result.text.substring(0, result.text.length.clamp(0, 50))}..."');
      }

      // Report progress based on chunks completed (reserve 10% for post-processing)
      final progress = 0.05 + ((chunkIndex + 1) / totalChunks) * 0.85;
      onProgress?.call(progress.clamp(0.0, 0.9));

      // Move to next chunk, with overlap to avoid cutting words
      chunkStart = chunkEnd - _overlapSamples;
      if (chunkStart >= totalSamples - _overlapSamples) {
        break; // Don't process tiny remaining chunks
      }
      chunkIndex++;

      // Small delay to allow GC to reclaim memory
      await Future.delayed(const Duration(milliseconds: 50));
    }

    onProgress?.call(0.92); // Deduplicating

    // Remove duplicate words from overlapping regions
    return _deduplicateChunkResults(results);
  }

  /// Transcribe a single chunk of audio
  Future<TranscriptionResult> _transcribeChunk(
    String audioPath,
    int startSample,
    int endSample,
  ) async {
    final startTime = DateTime.now();

    // Load only this chunk of samples
    final samples = await _loadWavChunk(audioPath, startSample, endSample);

    // Create stream for this chunk
    final stream = _recognizer!.createStream();

    // Accept waveform (16kHz sample rate)
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);

    // Decode
    _recognizer!.decode(stream);

    // Get result
    final result = _recognizer!.getResult(stream);
    final text = result.text.trim();
    final tokens = result.tokens;
    final timestamps = result.timestamps;

    // Free stream immediately to release memory
    stream.free();

    final duration = DateTime.now().difference(startTime);

    return TranscriptionResult(
      text: text,
      language: 'auto',
      duration: duration,
      tokens: tokens.isNotEmpty ? tokens : null,
      timestamps: timestamps.isNotEmpty ? timestamps : null,
    );
  }

  /// Remove duplicate words that appear due to chunk overlap
  List<TranscriptionResult> _deduplicateChunkResults(List<TranscriptionResult> results) {
    if (results.length <= 1) return results;

    final deduped = <TranscriptionResult>[results.first];

    for (int i = 1; i < results.length; i++) {
      final prevText = results[i - 1].text;
      final currText = results[i].text;

      // Find overlap by checking if end of previous matches start of current
      final dedupedText = _removeOverlap(prevText, currText);

      deduped.add(TranscriptionResult(
        text: dedupedText,
        language: results[i].language,
        duration: results[i].duration,
        tokens: results[i].tokens,
        timestamps: results[i].timestamps,
      ));
    }

    return deduped;
  }

  /// Remove overlapping words between consecutive chunks
  String _removeOverlap(String prevText, String currText) {
    if (prevText.isEmpty || currText.isEmpty) return currText;

    final prevWords = prevText.split(' ');
    final currWords = currText.split(' ');

    if (prevWords.isEmpty || currWords.isEmpty) return currText;

    // Look for overlap in last few words of prev and first few words of curr
    // Check up to 10 words for overlap
    final maxOverlapCheck = 10.clamp(0, prevWords.length).clamp(0, currWords.length);

    for (int overlapLen = maxOverlapCheck; overlapLen >= 2; overlapLen--) {
      final prevEnd = prevWords.sublist(prevWords.length - overlapLen).join(' ').toLowerCase();
      final currStart = currWords.sublist(0, overlapLen).join(' ').toLowerCase();

      if (prevEnd == currStart) {
        // Found overlap, remove it from current
        debugPrint('[SherpaOnnxService] Removing $overlapLen word overlap: "$currStart"');
        return currWords.sublist(overlapLen).join(' ');
      }
    }

    // No exact overlap found, return as-is
    return currText;
  }

  /// Load a chunk of WAV file and convert to Float32List samples
  ///
  /// [startSample] and [endSample] specify the range of samples to load.
  /// This avoids loading the entire file into memory for long recordings.
  Future<Float32List> _loadWavChunk(
    String audioPath,
    int startSample,
    int endSample,
  ) async {
    final file = File(audioPath);
    final raf = await file.open(mode: FileMode.read);

    try {
      // WAV header is 44 bytes, then PCM16 data (2 bytes per sample)
      const headerSize = 44;
      final startByte = headerSize + (startSample * 2);
      final numSamples = endSample - startSample;
      final numBytes = numSamples * 2;

      // Seek to start position and read only the needed bytes
      await raf.setPosition(startByte);
      final bytes = await raf.read(numBytes);

      // Convert to Float32List
      final samples = Float32List(numSamples);
      for (int i = 0; i < numSamples && (i * 2 + 1) < bytes.length; i++) {
        final byteIndex = i * 2;
        // Read 16-bit signed integer (little-endian)
        final sample = (bytes[byteIndex + 1] << 8) | bytes[byteIndex];
        // Convert to signed int16
        final signedSample = sample > 32767 ? sample - 65536 : sample;
        // Normalize to [-1.0, 1.0]
        samples[i] = signedSample / 32768.0;
      }

      debugPrint('[SherpaOnnxService] Loaded chunk: $numSamples samples (${(numSamples / _sampleRate).toStringAsFixed(1)}s)');
      return samples;
    } finally {
      await raf.close();
    }
  }

  /// Check if SherpaOnnx is ready
  Future<bool> isReady() async {
    return _isInitialized && _recognizer != null;
  }

  /// Get model information
  Future<ModelInfo?> getModelInfo() async {
    if (!_isInitialized) return null;

    return ModelInfo(
      version: 'v3-int8',
      languageCount: 25,
      isInitialized: true,
      modelPath: _modelPath,
    );
  }

  /// Clean up resources
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _isInitialized = false;
    debugPrint('[SherpaOnnxService] Disposed');
  }
}

/// Transcription result from Sherpa-ONNX
class TranscriptionResult {
  final String text;
  final String language;
  final Duration duration;
  final List<String>? tokens;
  final List<double>? timestamps;

  TranscriptionResult({
    required this.text,
    required this.language,
    required this.duration,
    this.tokens,
    this.timestamps,
  });

  @override
  String toString() =>
      'TranscriptionResult(text: "$text", language: $language, duration: ${duration.inMilliseconds}ms, tokens: ${tokens?.length ?? 0}, timestamps: ${timestamps?.length ?? 0})';
}

/// Model information
class ModelInfo {
  final String version;
  final int languageCount;
  final bool isInitialized;
  final String modelPath;

  ModelInfo({
    required this.version,
    required this.languageCount,
    required this.isInitialized,
    required this.modelPath,
  });

  @override
  String toString() =>
      'ModelInfo(version: $version, languages: $languageCount, initialized: $isInitialized, path: $modelPath)';
}
