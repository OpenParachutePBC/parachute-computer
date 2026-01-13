import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// Isolate-based wrapper for Sherpa-ONNX transcription to prevent UI blocking
///
/// Transcription runs in a dedicated background isolate with its own
/// recognizer instance. The main isolate stays responsive.
///
/// Ported from parachute-daily to fix "not responding" issue during long transcriptions.
class SherpaOnnxIsolate {
  static SherpaOnnxIsolate? _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _progressPort;
  final Completer<void> _ready = Completer<void>();
  bool _isInitialized = false;

  // Track if models are available (checked on main thread)
  bool _modelsAvailable = false;

  SherpaOnnxIsolate._();

  /// Get singleton instance
  static SherpaOnnxIsolate get instance {
    _instance ??= SherpaOnnxIsolate._();
    return _instance!;
  }

  bool get isInitialized => _isInitialized;
  bool get modelsAvailable => _modelsAvailable;

  /// Check if models are downloaded (can be called before initialization)
  Future<bool> checkModelsAvailable() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');
      final encoderFile = File(path.join(modelDir, 'encoder.int8.onnx'));
      final tokensFile = File(path.join(modelDir, 'tokens.txt'));

      if (!await encoderFile.exists() || !await tokensFile.exists()) {
        _modelsAvailable = false;
        return false;
      }

      final encoderSize = await encoderFile.length();
      final tokensSize = await tokensFile.length();

      _modelsAvailable = encoderSize > 100 * 1024 * 1024 && tokensSize > 1000;
      return _modelsAvailable;
    } catch (e) {
      _modelsAvailable = false;
      return false;
    }
  }

  /// Initialize the transcription isolate
  ///
  /// This spawns a background isolate that loads the Sherpa-ONNX recognizer.
  /// Progress callbacks are for model download/initialization.
  Future<void> initialize({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    if (_isInitialized) {
      debugPrint('[SherpaOnnxIsolate] Already initialized');
      onProgress?.call(1.0);
      onStatus?.call('Ready');
      return;
    }

    debugPrint('[SherpaOnnxIsolate] Starting background isolate...');
    onStatus?.call('Starting transcription service...');

    // Create ports for communication
    final receivePort = ReceivePort();
    final progressPort = ReceivePort();

    // Listen for progress updates from isolate
    _progressPort = progressPort;
    progressPort.listen((message) {
      if (message is Map<String, dynamic>) {
        if (message['type'] == 'progress') {
          onProgress?.call(message['value'] as double);
        } else if (message['type'] == 'status') {
          onStatus?.call(message['value'] as String);
        } else if (message['type'] == 'transcribe_progress') {
          // Forward transcription progress to callback if set
          _transcribeProgressCallback?.call(message['value'] as double);
        }
      }
    });

    // Get root isolate token for platform channel access in background isolate
    final rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      throw StateError('RootIsolateToken not available');
    }

    // Spawn isolate
    _isolate = await Isolate.spawn(
      _isolateEntry,
      _IsolateConfig(
        mainSendPort: receivePort.sendPort,
        progressSendPort: progressPort.sendPort,
        rootIsolateToken: rootIsolateToken,
      ),
    );

    // Wait for isolate to send back its SendPort
    final completer = Completer<SendPort>();

    receivePort.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      } else if (message is _IsolateResult) {
        // Handle async results (will be processed in transcribe method)
      }
    });

    _sendPort = await completer.future;

    // Send initialize command and wait for completion
    final initCompleter = Completer<void>();

    final initReceiver = ReceivePort();
    _sendPort!.send(_IsolateCommand(
      type: _CommandType.initialize,
      responsePort: initReceiver.sendPort,
    ));

    initReceiver.listen((message) {
      if (message is _IsolateResult) {
        if (message.success) {
          _isInitialized = true;
          _modelsAvailable = true;
          initCompleter.complete();
        } else {
          initCompleter.completeError(
            StateError(message.error ?? 'Initialization failed'),
          );
        }
        initReceiver.close();
      }
    });

    await initCompleter.future;
    _ready.complete();

    debugPrint('[SherpaOnnxIsolate] ✅ Background isolate ready');
  }

  /// Transcribe audio file in background isolate
  ///
  /// [onProgress] - Optional callback for progress updates (0.0-1.0)
  ///
  /// Returns transcription result without blocking UI thread.
  Future<TranscriptionResult> transcribeAudio(
    String audioPath, {
    Function(double progress)? onProgress,
  }) async {
    if (!_isInitialized || _sendPort == null) {
      throw StateError('SherpaOnnxIsolate not initialized. Call initialize() first.');
    }

    await _ready.future;

    final responsePort = ReceivePort();
    final completer = Completer<TranscriptionResult>();

    // Set up progress callback if provided
    if (onProgress != null && _progressPort != null) {
      _transcribeProgressCallback = onProgress;
    }

    responsePort.listen((message) {
      if (message is _IsolateResult) {
        _transcribeProgressCallback = null; // Clear callback
        if (message.success && message.result != null) {
          completer.complete(message.result);
        } else {
          completer.completeError(
            Exception(message.error ?? 'Transcription failed'),
          );
        }
        responsePort.close();
      }
    });

    _sendPort!.send(_IsolateCommand(
      type: _CommandType.transcribe,
      audioPath: audioPath,
      responsePort: responsePort.sendPort,
    ));

    return completer.future;
  }

  // Callback for transcription progress (set temporarily during transcription)
  Function(double)? _transcribeProgressCallback;

  /// Dispose the isolate
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _progressPort?.close();
    _progressPort = null;
    _isInitialized = false;
    _instance = null;
  }
}

/// Isolate entry point
@pragma('vm:entry-point')
Future<void> _isolateEntry(_IsolateConfig config) async {
  debugPrint('[SherpaOnnxIsolate:Worker] Starting...');

  // Initialize platform channel access for background isolate
  BackgroundIsolateBinaryMessenger.ensureInitialized(config.rootIsolateToken);

  final receivePort = ReceivePort();
  final worker = _IsolateWorker();

  // Send our SendPort back to main isolate
  config.mainSendPort.send(receivePort.sendPort);

  // Listen for commands
  await for (final message in receivePort) {
    if (message is _IsolateCommand) {
      switch (message.type) {
        case _CommandType.initialize:
          await worker.handleInitialize(message, config.progressSendPort);
          break;
        case _CommandType.transcribe:
          await worker.handleTranscribe(message, config.progressSendPort);
          break;
        case _CommandType.dispose:
          worker.dispose();
          receivePort.close();
          return;
      }
    }
  }
}

/// Worker class that runs inside the isolate
class _IsolateWorker {
  sherpa.OfflineRecognizer? _recognizer;
  String _modelPath = '';

  Future<void> handleInitialize(
    _IsolateCommand command,
    SendPort progressPort,
  ) async {
    try {
      progressPort.send({'type': 'status', 'value': 'Loading models...'});
      progressPort.send({'type': 'progress', 'value': 0.1});

      // Get model directory
      final appDir = await getApplicationDocumentsDirectory();
      _modelPath = path.join(appDir.path, 'models', 'parakeet-v3');

      progressPort.send({'type': 'status', 'value': 'Configuring model...'});
      progressPort.send({'type': 'progress', 'value': 0.5});

      // Configure Parakeet TDT model
      final modelConfig = sherpa.OfflineTransducerModelConfig(
        encoder: path.join(_modelPath, 'encoder.int8.onnx'),
        decoder: path.join(_modelPath, 'decoder.int8.onnx'),
        joiner: path.join(_modelPath, 'joiner.int8.onnx'),
      );

      final numThreads = Platform.numberOfProcessors;
      final optimalThreads = (numThreads * 0.75).ceil().clamp(4, 8);

      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: modelConfig,
          tokens: path.join(_modelPath, 'tokens.txt'),
          numThreads: optimalThreads,
          debug: kDebugMode,
          modelType: 'nemo_transducer',
        ),
      );

      progressPort.send({'type': 'status', 'value': 'Initializing recognizer...'});
      progressPort.send({'type': 'progress', 'value': 0.8});

      sherpa.initBindings();
      _recognizer = sherpa.OfflineRecognizer(config);

      progressPort.send({'type': 'progress', 'value': 1.0});
      progressPort.send({'type': 'status', 'value': 'Ready'});

      command.responsePort?.send(_IsolateResult(success: true));
    } catch (e) {
      command.responsePort?.send(_IsolateResult(
        success: false,
        error: e.toString(),
      ));
    }
  }

  Future<void> handleTranscribe(
    _IsolateCommand command,
    SendPort progressPort,
  ) async {
    try {
      if (command.audioPath == null) {
        throw ArgumentError('audioPath is required for transcription');
      }

      if (_recognizer == null) {
        throw StateError('Recognizer not initialized');
      }

      final audioPath = command.audioPath!;
      final file = File(audioPath);
      if (!await file.exists()) {
        throw ArgumentError('Audio file not found: $audioPath');
      }

      final startTime = DateTime.now();
      progressPort.send({'type': 'transcribe_progress', 'value': 0.1});

      // Load WAV samples
      final samples = await _loadWavSamples(audioPath);
      progressPort.send({'type': 'transcribe_progress', 'value': 0.3});

      // Create stream and transcribe
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);

      progressPort.send({'type': 'transcribe_progress', 'value': 0.5});

      _recognizer!.decode(stream);

      progressPort.send({'type': 'transcribe_progress', 'value': 0.8});

      final result = _recognizer!.getResult(stream);
      stream.free();

      final duration = DateTime.now().difference(startTime);
      progressPort.send({'type': 'transcribe_progress', 'value': 1.0});

      debugPrint('[SherpaOnnxIsolate:Worker] ✅ Transcribed in ${duration.inMilliseconds}ms');

      command.responsePort?.send(_IsolateResult(
        success: true,
        result: TranscriptionResult(
          text: result.text.trim(),
          language: 'auto',
          duration: duration,
        ),
      ));
    } catch (e) {
      command.responsePort?.send(_IsolateResult(
        success: false,
        error: e.toString(),
      ));
    }
  }

  Future<Float32List> _loadWavSamples(String audioPath) async {
    final file = File(audioPath);
    final bytes = await file.readAsBytes();

    // Skip WAV header (44 bytes), convert PCM16 to float
    const headerSize = 44;
    final numSamples = (bytes.length - headerSize) ~/ 2;
    final samples = Float32List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final byteIndex = headerSize + (i * 2);
      if (byteIndex + 1 >= bytes.length) break;

      final sample = (bytes[byteIndex + 1] << 8) | bytes[byteIndex];
      final signedSample = sample > 32767 ? sample - 65536 : sample;
      samples[i] = signedSample / 32768.0;
    }

    return samples;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
  }
}

/// Configuration passed to isolate at spawn
class _IsolateConfig {
  final SendPort mainSendPort;
  final SendPort progressSendPort;
  final RootIsolateToken rootIsolateToken;

  _IsolateConfig({
    required this.mainSendPort,
    required this.progressSendPort,
    required this.rootIsolateToken,
  });
}

/// Command types for isolate
enum _CommandType {
  initialize,
  transcribe,
  dispose,
}

/// Command sent to isolate
class _IsolateCommand {
  final _CommandType type;
  final String? audioPath;
  final SendPort? responsePort;

  _IsolateCommand({
    required this.type,
    this.audioPath,
    this.responsePort,
  });
}

/// Result from isolate
class _IsolateResult {
  final bool success;
  final TranscriptionResult? result;
  final String? error;

  _IsolateResult({
    required this.success,
    this.result,
    this.error,
  });
}

/// Transcription result
class TranscriptionResult {
  final String text;
  final String language;
  final Duration duration;

  TranscriptionResult({
    required this.text,
    required this.language,
    required this.duration,
  });

  @override
  String toString() =>
      'TranscriptionResult(text: "$text", language: $language, duration: ${duration.inMilliseconds}ms)';
}
