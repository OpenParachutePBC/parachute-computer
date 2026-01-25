import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

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

    // Check if a server is already running on our port
    // This prevents conflicts when running in dev mode with ./parachute.sh already started
    if (await _isPortInUse()) {
      debugPrint('[BundledServerService] Port $port already in use - assuming external server is running');
      debugPrint('[BundledServerService] Will use existing server instead of starting bundled one');
      _updateStatus(ServerStatus.notBundled); // Treat as externally managed
      return;
    }

    _updateStatus(ServerStatus.stopped);

    if (autoStart) {
      await start();
    }
  }

  /// Check if the target port is already in use (another server running)
  Future<bool> _isPortInUse() async {
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 2));
      // If we get a response, the port is in use
      return response.statusCode == 200;
    } catch (e) {
      // Connection refused or timeout = port not in use
      return false;
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
      // Get vault path from SharedPreferences (user's choice from onboarding/settings)
      // Fall back to env var or default home directory
      String vaultPath;
      final prefs = await SharedPreferences.getInstance();

      // Check SharedPreferences first (matches FileSystemService key pattern)
      final savedVaultPath = prefs.getString('daily_vault_path') ??
                             prefs.getString('chat_vault_path');

      if (savedVaultPath != null && savedVaultPath.isNotEmpty) {
        vaultPath = savedVaultPath;
        debugPrint('[BundledServerService] Using saved vault path: $vaultPath');
      } else if (Platform.environment.containsKey('PARACHUTE_VAULT_PATH')) {
        vaultPath = Platform.environment['PARACHUTE_VAULT_PATH']!;
        debugPrint('[BundledServerService] Using env var vault path: $vaultPath');
      } else {
        // Get real user home directory (not sandboxed container)
        // On macOS, we can use /Users/<username> directly
        final home = Platform.environment['HOME'] ?? '/tmp';
        if (Platform.isMacOS && home.contains('/Library/Containers/')) {
          // Extract real home from sandboxed path
          // /Users/username/Library/Containers/... -> /Users/username
          final match = RegExp(r'^(/Users/[^/]+)').firstMatch(home);
          vaultPath = match?.group(1) ?? home;
        } else {
          vaultPath = home;
        }
        debugPrint('[BundledServerService] Using default vault path: $vaultPath');
      }

      // Ensure vault directory exists
      final vaultDir = Directory(vaultPath);
      if (!vaultDir.existsSync()) {
        vaultDir.createSync(recursive: true);
        debugPrint('[BundledServerService] Created vault at: $vaultPath');
      }

      debugPrint('[BundledServerService] Starting server: $binary');
      debugPrint('[BundledServerService] Vault path: $vaultPath');
      debugPrint('[BundledServerService] Port: $port');
      debugPrint('[BundledServerService] Working dir: ${path.dirname(binary)}');

      try {
        _serverProcess = await Process.start(
          binary,
          [],
          environment: {
            'VAULT_PATH': vaultPath,
            'PORT': port.toString(),
            // Inherit PATH for any external tools
            'PATH': Platform.environment['PATH'] ?? '',
            // Pass HOME explicitly for tools that need it
            'HOME': Platform.environment['HOME'] ?? '/tmp',
          },
          workingDirectory: path.dirname(binary),
        );

        debugPrint('[BundledServerService] Process started with PID: ${_serverProcess!.pid}');
      } catch (procError) {
        debugPrint('[BundledServerService] Process.start failed: $procError');
        _lastError = 'Failed to start server process: $procError';
        _updateStatus(ServerStatus.error);
        return false;
      }

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

      debugPrint('[BundledServerService] Checking bundled path: $serverPath');
      if (File(serverPath).existsSync()) {
        debugPrint('[BundledServerService] Found bundled server at: $serverPath');
        return serverPath;
      }
      debugPrint('[BundledServerService] Bundled server not found at: $serverPath');

      // Also check for development mode (server in sibling directory)
      // When running from Xcode/flutter run, the executable is at:
      // .../app/build/macos/Build/Products/Debug/parachute.app/Contents/MacOS/parachute
      // And we need to get to:
      // .../base/dist/parachute-server/parachute-server
      //
      // Count up from executable: MacOS -> Contents -> parachute.app -> Debug -> Products -> Build -> macos -> build -> app
      // Then go to: ../base/dist/parachute-server/parachute-server
      var current = path.dirname(execPath); // MacOS
      for (var i = 0; i < 8; i++) {
        current = path.dirname(current);
      }
      // Now we should be at the 'app' directory
      final projectRoot = path.dirname(current); // parent of 'app' is project root
      final devServerPath = path.join(
        projectRoot,
        'base',
        'dist',
        'parachute-server',
        'parachute-server',
      );
      debugPrint('[BundledServerService] Checking dev path: $devServerPath');
      if (File(devServerPath).existsSync()) {
        debugPrint('[BundledServerService] Found dev server at: $devServerPath');
        return devServerPath;
      }
      debugPrint('[BundledServerService] Dev server not found at: $devServerPath');
    } else if (Platform.isLinux) {
      // Linux bundle structure:
      // parachute-linux-x64/parachute (executable)
      // parachute-linux-x64/lib/parachute-server/parachute-server (server)
      final bundleDir = path.dirname(execPath);
      final serverPath = path.join(
        bundleDir,
        'lib',
        'parachute-server',
        'parachute-server',
      );
      debugPrint('[BundledServerService] Checking Linux bundled path: $serverPath');
      if (File(serverPath).existsSync()) {
        debugPrint('[BundledServerService] Found bundled server at: $serverPath');
        return serverPath;
      }

      // Dev mode: check sibling base directory
      // .../app/build/linux/x64/release/bundle/parachute -> .../base/dist/parachute-server/
      var current = bundleDir;
      for (var i = 0; i < 6; i++) {
        current = path.dirname(current);
      }
      final projectRoot = path.dirname(current);
      final devServerPath = path.join(
        projectRoot,
        'base',
        'dist',
        'parachute-server',
        'parachute-server',
      );
      debugPrint('[BundledServerService] Checking Linux dev path: $devServerPath');
      if (File(devServerPath).existsSync()) {
        debugPrint('[BundledServerService] Found dev server at: $devServerPath');
        return devServerPath;
      }
    } else if (Platform.isWindows) {
      // Windows bundle structure:
      // parachute-windows-x64/parachute.exe (executable)
      // parachute-windows-x64/data/parachute-server/parachute-server.exe (server)
      final bundleDir = path.dirname(execPath);
      final serverPath = path.join(
        bundleDir,
        'data',
        'parachute-server',
        'parachute-server.exe',
      );
      debugPrint('[BundledServerService] Checking Windows bundled path: $serverPath');
      if (File(serverPath).existsSync()) {
        debugPrint('[BundledServerService] Found bundled server at: $serverPath');
        return serverPath;
      }

      // Dev mode: check sibling base directory
      // .../app/build/windows/x64/runner/Release/parachute.exe -> .../base/dist/parachute-server/
      var current = bundleDir;
      for (var i = 0; i < 6; i++) {
        current = path.dirname(current);
      }
      final projectRoot = path.dirname(current);
      final devServerPath = path.join(
        projectRoot,
        'base',
        'dist',
        'parachute-server',
        'parachute-server.exe',
      );
      debugPrint('[BundledServerService] Checking Windows dev path: $devServerPath');
      if (File(devServerPath).existsSync()) {
        debugPrint('[BundledServerService] Found dev server at: $devServerPath');
        return devServerPath;
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
