import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'sherpa_onnx_service.dart';

/// Isolate-based wrapper for SherpaOnnxService to prevent UI blocking
///
/// Transcription runs in a dedicated background isolate with its own
/// SherpaOnnxService instance. The main isolate stays responsive.
class SherpaOnnxIsolate {
  static SherpaOnnxIsolate? _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _progressPort;
  final Completer<void> _ready = Completer<void>();
  bool _isInitialized = false;

  // Track if initialization is in progress to prevent race conditions
  bool _isInitializing = false;
  Completer<void>? _initCompleter;

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
    final service = SherpaOnnxService();
    _modelsAvailable = await service.hasModelsDownloaded;
    return _modelsAvailable;
  }

  /// Initialize the transcription isolate
  ///
  /// This spawns a background isolate that loads the SherpaOnnxService.
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

    // If initialization is already in progress, wait for it to complete
    if (_isInitializing && _initCompleter != null) {
      debugPrint('[SherpaOnnxIsolate] Initialization already in progress, waiting...');
      onStatus?.call('Waiting for initialization...');
      await _initCompleter!.future;
      onProgress?.call(1.0);
      onStatus?.call('Ready');
      return;
    }

    // Mark initialization as in progress
    _isInitializing = true;
    _initCompleter = Completer<void>();

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

    try {
      await initCompleter.future;
      _ready.complete();
      debugPrint('[SherpaOnnxIsolate] ✅ Background isolate ready');
      // Signal any waiting callers that init is done
      _initCompleter?.complete();
    } catch (e) {
      // Signal error to waiting callers
      _initCompleter?.completeError(e);
      rethrow;
    } finally {
      _isInitializing = false;
    }
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
    // Progress updates come through the existing progress port listener
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
    _isInitialized = false;
    _instance = null;
  }
}

/// Isolate entry point
@pragma('vm:entry-point')
Future<void> _isolateEntry(_IsolateConfig config) async {
  debugPrint('[SherpaOnnxIsolate:Worker] Starting...');

  // Initialize platform channel access for background isolate
  // This is required for plugins that use platform channels (like path_provider)
  BackgroundIsolateBinaryMessenger.ensureInitialized(config.rootIsolateToken);

  final receivePort = ReceivePort();
  final service = SherpaOnnxService();

  // Send our SendPort back to main isolate
  config.mainSendPort.send(receivePort.sendPort);

  // Listen for commands
  await for (final message in receivePort) {
    if (message is _IsolateCommand) {
      switch (message.type) {
        case _CommandType.initialize:
          await _handleInitialize(service, message, config.progressSendPort);
          break;
        case _CommandType.transcribe:
          await _handleTranscribe(service, message, config.progressSendPort);
          break;
        case _CommandType.dispose:
          service.dispose();
          receivePort.close();
          return;
      }
    }
  }
}

Future<void> _handleInitialize(
  SherpaOnnxService service,
  _IsolateCommand command,
  SendPort progressPort,
) async {
  try {
    await service.initialize(
      onProgress: (progress) {
        progressPort.send({'type': 'progress', 'value': progress});
      },
      onStatus: (status) {
        progressPort.send({'type': 'status', 'value': status});
      },
    );

    command.responsePort?.send(_IsolateResult(success: true));
  } catch (e) {
    command.responsePort?.send(_IsolateResult(
      success: false,
      error: e.toString(),
    ));
  }
}

Future<void> _handleTranscribe(
  SherpaOnnxService service,
  _IsolateCommand command,
  SendPort progressPort,
) async {
  try {
    if (command.audioPath == null) {
      throw ArgumentError('audioPath is required for transcription');
    }

    final result = await service.transcribeAudio(
      command.audioPath!,
      onProgress: (progress) {
        // Send progress back to main isolate
        progressPort.send({'type': 'transcribe_progress', 'value': progress});
      },
    );

    command.responsePort?.send(_IsolateResult(
      success: true,
      result: result,
    ));
  } catch (e) {
    command.responsePort?.send(_IsolateResult(
      success: false,
      error: e.toString(),
    ));
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
