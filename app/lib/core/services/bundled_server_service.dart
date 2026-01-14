import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Status of the bundled server
enum ServerStatus {
  /// Not a bundled app - server managed externally
  notBundled,

  /// Bundled but server not started
  stopped,

  /// Server is starting up
  starting,

  /// Server is running and healthy
  running,

  /// Server failed to start or crashed
  error,
}

/// Service to manage the bundled Parachute server process.
///
/// On macOS, the server binary is bundled inside the app bundle at:
/// MyApp.app/Contents/Resources/parachute-server/parachute-server
///
/// This service handles:
/// - Detecting if we're running as a bundled app
/// - Starting/stopping the server process
/// - Health monitoring with automatic restart
/// - Providing server URL for the rest of the app
class BundledServerService {
  BundledServerService({
    this.port = 3333,
    this.healthCheckInterval = const Duration(seconds: 10),
    this.startupTimeout = const Duration(seconds: 30),
  });

  final int port;
  final Duration healthCheckInterval;
  final Duration startupTimeout;

  Process? _serverProcess;
  Timer? _healthCheckTimer;
  final _statusController = StreamController<ServerStatus>.broadcast();
  ServerStatus _currentStatus = ServerStatus.notBundled;
  String? _lastError;
  int _restartAttempts = 0;
  static const _maxRestartAttempts = 3;

  /// Stream of server status changes
  Stream<ServerStatus> get statusStream => _statusController.stream;

  /// Current server status
  ServerStatus get status => _currentStatus;

  /// Last error message if status is error
  String? get lastError => _lastError;

  /// Server URL if running
  String get serverUrl => 'http://localhost:$port';

  /// Whether this app has a bundled server
  bool get isBundled => _findServerBinary() != null;

  /// Initialize the service - detect bundle and optionally auto-start
  Future<void> initialize({bool autoStart = true}) async {
    final binary = _findServerBinary();
    if (binary == null) {
      debugPrint('[BundledServerService] Not a bundled app, server managed externally');
      _updateStatus(ServerStatus.notBundled);
      return;
    }

    debugPrint('[BundledServerService] Found bundled server at: $binary');
    _updateStatus(ServerStatus.stopped);

    if (autoStart) {
      await start();
    }
  }

  /// Start the bundled server
  Future<bool> start() async {
    final binary = _findServerBinary();
    if (binary == null) {
      _lastError = 'Server binary not found';
      _updateStatus(ServerStatus.error);
      return false;
    }

    if (_serverProcess != null) {
      debugPrint('[BundledServerService] Server already running');
      return true;
    }

    _updateStatus(ServerStatus.starting);
    _lastError = null;

    try {
      // Get vault path (default to ~/Parachute)
      final home = Platform.environment['HOME'] ?? '/tmp';
      final vaultPath = Platform.environment['PARACHUTE_VAULT_PATH'] ??
          path.join(home, 'Parachute');

      // Ensure vault directory exists
      final vaultDir = Directory(vaultPath);
      if (!vaultDir.existsSync()) {
        vaultDir.createSync(recursive: true);
        debugPrint('[BundledServerService] Created vault at: $vaultPath');
      }

      debugPrint('[BundledServerService] Starting server: $binary');
      debugPrint('[BundledServerService] Vault path: $vaultPath');
      debugPrint('[BundledServerService] Port: $port');

      _serverProcess = await Process.start(
        binary,
        [],
        environment: {
          'VAULT_PATH': vaultPath,
          'PORT': port.toString(),
          // Inherit PATH for any external tools
          'PATH': Platform.environment['PATH'] ?? '',
        },
        workingDirectory: path.dirname(binary),
      );

      // Log stdout/stderr
      _serverProcess!.stdout.transform(utf8.decoder).listen((data) {
        debugPrint('[Server] $data');
      });
      _serverProcess!.stderr.transform(utf8.decoder).listen((data) {
        debugPrint('[Server ERR] $data');
      });

      // Monitor process exit
      _serverProcess!.exitCode.then((exitCode) {
        debugPrint('[BundledServerService] Server exited with code: $exitCode');
        _serverProcess = null;

        if (_currentStatus == ServerStatus.running) {
          // Unexpected exit - try to restart
          _handleUnexpectedExit(exitCode);
        }
      });

      // Wait for server to be healthy
      final healthy = await _waitForHealthy();
      if (healthy) {
        _updateStatus(ServerStatus.running);
        _restartAttempts = 0;
        _startHealthMonitor();
        return true;
      } else {
        _lastError = 'Server failed to become healthy within timeout';
        _updateStatus(ServerStatus.error);
        await stop();
        return false;
      }
    } catch (e) {
      _lastError = e.toString();
      _updateStatus(ServerStatus.error);
      debugPrint('[BundledServerService] Failed to start: $e');
      return false;
    }
  }

  /// Stop the bundled server
  Future<void> stop() async {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    if (_serverProcess != null) {
      debugPrint('[BundledServerService] Stopping server...');

      // Try graceful shutdown first
      _serverProcess!.kill(ProcessSignal.sigterm);

      // Wait a bit then force kill
      await Future.delayed(const Duration(seconds: 2));
      if (_serverProcess != null) {
        _serverProcess!.kill(ProcessSignal.sigkill);
      }

      _serverProcess = null;
    }

    if (_currentStatus != ServerStatus.notBundled) {
      _updateStatus(ServerStatus.stopped);
    }
  }

  /// Restart the server
  Future<bool> restart() async {
    await stop();
    await Future.delayed(const Duration(milliseconds: 500));
    return start();
  }

  /// Dispose the service
  Future<void> dispose() async {
    await stop();
    await _statusController.close();
  }

  /// Find the server binary path
  String? _findServerBinary() {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      return null; // Mobile platforms don't bundle server
    }

    // Get the executable path
    final execPath = Platform.resolvedExecutable;
    debugPrint('[BundledServerService] Executable path: $execPath');

    if (Platform.isMacOS) {
      // macOS app bundle structure:
      // MyApp.app/Contents/MacOS/MyApp (executable)
      // MyApp.app/Contents/Resources/parachute-server/parachute-server (server)
      final appBundle = path.dirname(path.dirname(execPath));
      final serverPath = path.join(
        appBundle,
        'Resources',
        'parachute-server',
        'parachute-server',
      );

      if (File(serverPath).existsSync()) {
        return serverPath;
      }

      // Also check for development mode (server in sibling directory)
      final devServerPath = path.join(
        path.dirname(path.dirname(path.dirname(execPath))),
        'base',
        'dist',
        'parachute-server',
        'parachute-server',
      );
      if (File(devServerPath).existsSync()) {
        return devServerPath;
      }
    } else if (Platform.isLinux) {
      // Linux: server next to executable
      final serverPath = path.join(
        path.dirname(execPath),
        'parachute-server',
        'parachute-server',
      );
      if (File(serverPath).existsSync()) {
        return serverPath;
      }
    } else if (Platform.isWindows) {
      // Windows: server next to executable
      final serverPath = path.join(
        path.dirname(execPath),
        'parachute-server',
        'parachute-server.exe',
      );
      if (File(serverPath).existsSync()) {
        return serverPath;
      }
    }

    return null;
  }

  /// Wait for server to become healthy
  Future<bool> _waitForHealthy() async {
    final deadline = DateTime.now().add(startupTimeout);

    while (DateTime.now().isBefore(deadline)) {
      if (await _checkHealth()) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    return false;
  }

  /// Check server health
  Future<bool> _checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['status'] == 'ok';
      }
    } catch (e) {
      // Expected during startup
    }
    return false;
  }

  /// Start health monitoring
  void _startHealthMonitor() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(healthCheckInterval, (_) async {
      if (_currentStatus == ServerStatus.running) {
        final healthy = await _checkHealth();
        if (!healthy) {
          debugPrint('[BundledServerService] Health check failed');
          _handleUnexpectedExit(-1);
        }
      }
    });
  }

  /// Handle unexpected server exit
  void _handleUnexpectedExit(int exitCode) {
    _serverProcess = null;
    _healthCheckTimer?.cancel();

    if (_restartAttempts < _maxRestartAttempts) {
      _restartAttempts++;
      debugPrint(
        '[BundledServerService] Attempting restart $_restartAttempts/$_maxRestartAttempts',
      );
      _updateStatus(ServerStatus.starting);
      start();
    } else {
      _lastError = 'Server crashed (exit code: $exitCode) after $_maxRestartAttempts restart attempts';
      _updateStatus(ServerStatus.error);
    }
  }

  /// Update status and notify listeners
  void _updateStatus(ServerStatus newStatus) {
    if (_currentStatus != newStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
      debugPrint('[BundledServerService] Status: $newStatus');
    }
  }
}
