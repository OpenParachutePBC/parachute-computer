import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Model download status
enum ModelDownloadStatus {
  /// Not started yet
  notStarted,
  /// Currently downloading
  downloading,
  /// Extracting the archive
  extracting,
  /// Download complete, ready to use
  ready,
  /// Download failed
  failed,
}

/// Model download state with progress
class ModelDownloadState {
  final ModelDownloadStatus status;
  final double progress; // 0.0 - 1.0
  final String? statusMessage;
  final String? error;
  final int? downloadedBytes;
  final int? totalBytes;

  const ModelDownloadState({
    this.status = ModelDownloadStatus.notStarted,
    this.progress = 0.0,
    this.statusMessage,
    this.error,
    this.downloadedBytes,
    this.totalBytes,
  });

  ModelDownloadState copyWith({
    ModelDownloadStatus? status,
    double? progress,
    String? statusMessage,
    String? error,
    int? downloadedBytes,
    int? totalBytes,
  }) {
    return ModelDownloadState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      error: error ?? this.error,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
    );
  }

  bool get isReady => status == ModelDownloadStatus.ready;
  bool get isDownloading => status == ModelDownloadStatus.downloading || status == ModelDownloadStatus.extracting;
  bool get needsDownload => status == ModelDownloadStatus.notStarted || status == ModelDownloadStatus.failed;

  String get progressText {
    if (downloadedBytes != null && totalBytes != null && totalBytes! > 0) {
      final downloadedMB = (downloadedBytes! / (1024 * 1024)).toStringAsFixed(0);
      final totalMB = (totalBytes! / (1024 * 1024)).toStringAsFixed(0);
      return '$downloadedMB / $totalMB MB';
    }
    return '${(progress * 100).toStringAsFixed(0)}%';
  }
}

/// Service for managing transcription model downloads
///
/// Features:
/// - Background downloading with progress tracking
/// - Resume support (checks existing files)
/// - Singleton to prevent duplicate downloads
/// - Persistent state across app restarts
class ModelDownloadService {
  static final ModelDownloadService _instance = ModelDownloadService._internal();
  factory ModelDownloadService() => _instance;
  ModelDownloadService._internal();

  static const String _modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2';
  static const String _prefsKeyDownloadComplete = 'parakeet_model_download_complete';
  static const int _expectedModelSize = 465 * 1024 * 1024; // ~465MB

  final _stateController = StreamController<ModelDownloadState>.broadcast();
  Stream<ModelDownloadState> get stateStream => _stateController.stream;

  ModelDownloadState _currentState = const ModelDownloadState();
  ModelDownloadState get currentState => _currentState;

  bool _isDownloading = false;
  http.Client? _httpClient;

  /// Check if models are already downloaded and valid
  Future<bool> areModelsReady() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');

      final encoderFile = File(path.join(modelDir, 'encoder.int8.onnx'));
      final decoderFile = File(path.join(modelDir, 'decoder.int8.onnx'));
      final joinerFile = File(path.join(modelDir, 'joiner.int8.onnx'));
      final tokensFile = File(path.join(modelDir, 'tokens.txt'));

      if (!await encoderFile.exists() ||
          !await decoderFile.exists() ||
          !await joinerFile.exists() ||
          !await tokensFile.exists()) {
        return false;
      }

      // Verify files are not empty/corrupted
      final encoderSize = await encoderFile.length();
      final tokensSize = await tokensFile.length();

      // Encoder should be ~130MB, tokens should be ~1KB
      if (encoderSize < 100 * 1024 * 1024 || tokensSize < 1000) {
        debugPrint('[ModelDownloadService] Model files appear corrupted');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[ModelDownloadService] Error checking models: $e');
      return false;
    }
  }

  /// Initialize - check current state and update
  Future<void> initialize() async {
    final isReady = await areModelsReady();
    if (isReady) {
      _updateState(_currentState.copyWith(
        status: ModelDownloadStatus.ready,
        progress: 1.0,
        statusMessage: 'Models ready',
      ));
    } else {
      _updateState(_currentState.copyWith(
        status: ModelDownloadStatus.notStarted,
        progress: 0.0,
        statusMessage: 'Models not downloaded',
      ));
    }
  }

  /// Start downloading models in the background
  ///
  /// Returns immediately - progress is reported via [stateStream]
  Future<void> startDownload() async {
    if (_isDownloading) {
      debugPrint('[ModelDownloadService] Download already in progress');
      return;
    }

    // Check if already ready
    if (await areModelsReady()) {
      _updateState(_currentState.copyWith(
        status: ModelDownloadStatus.ready,
        progress: 1.0,
        statusMessage: 'Models ready',
      ));
      return;
    }

    _isDownloading = true;
    _updateState(_currentState.copyWith(
      status: ModelDownloadStatus.downloading,
      progress: 0.0,
      statusMessage: 'Starting download...',
    ));

    try {
      await _downloadAndExtract();

      // Verify download succeeded
      if (await areModelsReady()) {
        // Mark as complete in preferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefsKeyDownloadComplete, true);

        _updateState(_currentState.copyWith(
          status: ModelDownloadStatus.ready,
          progress: 1.0,
          statusMessage: 'Models ready',
        ));
      } else {
        throw Exception('Model verification failed after download');
      }
    } catch (e) {
      debugPrint('[ModelDownloadService] Download failed: $e');
      _updateState(_currentState.copyWith(
        status: ModelDownloadStatus.failed,
        error: e.toString(),
        statusMessage: 'Download failed',
      ));
    } finally {
      _isDownloading = false;
      _httpClient?.close();
      _httpClient = null;
    }
  }

  Future<void> _downloadAndExtract() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');
    final archivePath = path.join(appDir.path, 'models', 'parakeet-v3-int8.tar.bz2');

    // Create model directory
    await Directory(modelDir).create(recursive: true);

    // Check if archive already exists (resume support)
    final archiveFile = File(archivePath);
    int startByte = 0;

    if (await archiveFile.exists()) {
      final existingSize = await archiveFile.length();
      if (existingSize > 0 && existingSize < _expectedModelSize) {
        // Partial download exists - try to resume
        startByte = existingSize;
        debugPrint('[ModelDownloadService] Resuming download from byte $startByte');
      } else if (existingSize >= _expectedModelSize * 0.95) {
        // Archive looks complete, skip to extraction
        debugPrint('[ModelDownloadService] Archive exists, skipping to extraction');
        await _extractArchive(archivePath, modelDir);
        return;
      }
    }

    // Download archive
    debugPrint('[ModelDownloadService] Downloading from $_modelUrl');
    _updateState(_currentState.copyWith(
      statusMessage: 'Downloading transcription model...',
    ));

    _httpClient = http.Client();
    final request = http.Request('GET', Uri.parse(_modelUrl));

    // Add range header for resume support
    if (startByte > 0) {
      request.headers['Range'] = 'bytes=$startByte-';
    }

    final response = await _httpClient!.send(request);

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    final totalBytes = (response.contentLength ?? _expectedModelSize) + startByte;
    int receivedBytes = startByte;

    // Open file for writing (append if resuming)
    final sink = archiveFile.openWrite(mode: startByte > 0 ? FileMode.append : FileMode.write);

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;

        // Report download progress (0.0 - 0.7 of total)
        final downloadProgress = receivedBytes / totalBytes;
        _updateState(_currentState.copyWith(
          progress: downloadProgress * 0.7,
          downloadedBytes: receivedBytes,
          totalBytes: totalBytes,
          statusMessage: 'Downloading transcription model...',
        ));
      }

      await sink.flush();
    } finally {
      await sink.close();
    }

    debugPrint('[ModelDownloadService] Download complete, extracting...');

    // Extract archive
    await _extractArchive(archivePath, modelDir);

    // Clean up archive
    try {
      await archiveFile.delete();
    } catch (e) {
      debugPrint('[ModelDownloadService] Failed to delete archive: $e');
    }
  }

  Future<void> _extractArchive(String archivePath, String modelDir) async {
    _updateState(_currentState.copyWith(
      status: ModelDownloadStatus.extracting,
      progress: 0.75,
      statusMessage: 'Extracting models (this may take a minute)...',
    ));

    // Extract in compute isolate to avoid blocking UI
    await compute(_extractArchiveIsolate, {
      'archivePath': archivePath,
      'modelDir': modelDir,
    });

    _updateState(_currentState.copyWith(
      progress: 0.95,
      statusMessage: 'Finalizing...',
    ));
  }

  static Future<void> _extractArchiveIsolate(Map<String, String> params) async {
    final archivePath = params['archivePath']!;
    final modelDir = params['modelDir']!;

    debugPrint('[ModelDownloadService] Reading archive...');
    final archiveBytes = await File(archivePath).readAsBytes();

    debugPrint('[ModelDownloadService] Decompressing BZip2...');
    final decompressed = BZip2Decoder().decodeBytes(archiveBytes);

    debugPrint('[ModelDownloadService] Extracting TAR...');
    final archive = TarDecoder().decodeBytes(decompressed);

    const targetFiles = [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ];

    for (final file in archive) {
      if (file.isFile) {
        final basename = path.basename(file.name);
        if (targetFiles.contains(basename)) {
          final outputPath = path.join(modelDir, basename);
          final outputFile = File(outputPath);
          await outputFile.create(recursive: true);
          await outputFile.writeAsBytes(file.content as List<int>);
          debugPrint('[ModelDownloadService] Extracted: $basename');
        }
      }
    }
  }

  void _updateState(ModelDownloadState state) {
    _currentState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Cancel any ongoing download
  void cancelDownload() {
    _httpClient?.close();
    _httpClient = null;
    _isDownloading = false;
    _updateState(_currentState.copyWith(
      status: ModelDownloadStatus.notStarted,
      statusMessage: 'Download cancelled',
    ));
  }

  void dispose() {
    _httpClient?.close();
    _stateController.close();
  }
}
