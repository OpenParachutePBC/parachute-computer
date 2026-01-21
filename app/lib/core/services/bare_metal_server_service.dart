import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Status of the bare metal server
enum BareMetalServerStatus {
  /// Python not installed or wrong version
  pythonNotInstalled,

  /// Server not installed (no base directory)
  notInstalled,

  /// Server installed but not running
  stopped,

  /// Server is starting up
  starting,

  /// Server is running
  running,

  /// Server is stopping
  stopping,

  /// Error state
  error,
}

/// Service for managing a bare metal Parachute server
///
/// This runs the server directly on macOS without a VM.
/// Best for dedicated Parachute machines where full performance is needed.
class BareMetalServerService {
  static const int serverPort = 3333;

  /// Version of base server bundled with this app
  /// This should match the version in base/parachute/__init__.py
  static const String bundledBaseVersion = '0.1.0';

  /// Minimum Python version required
  static const String minPythonVersion = '3.10';

  BareMetalServerStatus _currentStatus = BareMetalServerStatus.notInstalled;
  String? _lastError;
  final _statusController = StreamController<BareMetalServerStatus>.broadcast();

  /// Custom base path (if set by developer)
  String? _customBasePath;

  /// Stream of status changes
  Stream<BareMetalServerStatus> get statusStream => _statusController.stream;

  /// Current status
  BareMetalServerStatus get status => _currentStatus;

  /// Last error message if any
  String? get lastError => _lastError;

  /// Server URL when running
  String get serverUrl => 'http://localhost:$serverPort';

  /// Set custom base path (for developers)
  void setCustomBasePath(String? path) {
    _customBasePath = path;
  }

  /// Standard base server path in Application Support
  static String get _standardBasePath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Application Support/Parachute/base';
  }

  /// Get the active base server path
  /// Returns custom path if set, otherwise standard path
  String get baseServerPath {
    return _customBasePath ?? _standardBasePath;
  }

  /// Whether using a custom (developer) base path
  bool get isUsingCustomPath => _customBasePath != null;

  /// Known paths where Python might be installed
  static const List<String> _pythonPaths = [
    '/opt/homebrew/bin/python3', // Homebrew Apple Silicon
    '/usr/local/bin/python3', // Homebrew Intel
    '/usr/bin/python3', // System Python
  ];

  /// Get the path to Python 3, or null if not found
  String? get pythonPath {
    for (final p in _pythonPaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }
    return null;
  }

  /// Check if Python 3.10+ is installed
  Future<bool> isPythonInstalled() async {
    final python = pythonPath;
    if (python == null) return false;

    try {
      final result = await Process.run(python, ['--version']);
      if (result.exitCode != 0) return false;

      // Parse version from "Python 3.x.y"
      final output = result.stdout.toString().trim();
      final match = RegExp(r'Python (\d+)\.(\d+)').firstMatch(output);
      if (match == null) return false;

      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);

      // Require 3.10+
      return major > 3 || (major == 3 && minor >= 10);
    } catch (e) {
      debugPrint('[BareMetalServerService] Error checking Python: $e');
      return false;
    }
  }

  /// Get the installed Python version string
  Future<String?> getPythonVersion() async {
    final python = pythonPath;
    if (python == null) return null;

    try {
      final result = await Process.run(python, ['--version']);
      if (result.exitCode != 0) return null;
      return result.stdout.toString().trim();
    } catch (e) {
      return null;
    }
  }

  /// Check if base server is installed (has parachute.sh)
  Future<bool> isServerInstalled() async {
    final scriptPath = path.join(baseServerPath, 'parachute.sh');
    return File(scriptPath).exists();
  }

  /// Check if venv is set up
  Future<bool> isVenvSetup() async {
    final venvPython = path.join(baseServerPath, 'venv', 'bin', 'python');
    return File(venvPython).exists();
  }

  /// Get current server status
  Future<BareMetalServerStatus> checkStatus() async {
    try {
      // Check Python
      if (!await isPythonInstalled()) {
        _updateStatus(BareMetalServerStatus.pythonNotInstalled);
        return _currentStatus;
      }

      // Check if base is installed
      if (!await isServerInstalled()) {
        _updateStatus(BareMetalServerStatus.notInstalled);
        return _currentStatus;
      }

      // Check if server is running (port 3333)
      if (await isServerHealthy()) {
        _updateStatus(BareMetalServerStatus.running);
      } else {
        _updateStatus(BareMetalServerStatus.stopped);
      }

      return _currentStatus;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error checking status: $e');
      _lastError = e.toString();
      _updateStatus(BareMetalServerStatus.error);
      return _currentStatus;
    }
  }

  /// Run parachute.sh with given command
  Future<ProcessResult?> _runParachuteScript(String command) async {
    final scriptPath = path.join(baseServerPath, 'parachute.sh');
    if (!await File(scriptPath).exists()) {
      _lastError = 'parachute.sh not found at $scriptPath';
      return null;
    }

    try {
      return await Process.run(
        'bash',
        [scriptPath, command],
        workingDirectory: baseServerPath,
        environment: {
          ...Platform.environment,
          'VAULT_PATH': Platform.environment['HOME'] ?? '',
        },
      );
    } catch (e) {
      _lastError = 'Error running parachute.sh: $e';
      return null;
    }
  }

  /// Set up the server (create venv, install dependencies)
  Future<bool> setupServer() async {
    _updateStatus(BareMetalServerStatus.starting);
    _lastError = null;

    try {
      debugPrint('[BareMetalServerService] Running setup...');

      final result = await _runParachuteScript('setup');
      if (result == null) {
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      if (result.exitCode == 0) {
        debugPrint('[BareMetalServerService] Setup complete');
        _updateStatus(BareMetalServerStatus.stopped);
        return true;
      } else {
        _lastError = result.stderr.toString();
        debugPrint('[BareMetalServerService] Setup failed: $_lastError');
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error during setup: $e');
      _lastError = e.toString();
      _updateStatus(BareMetalServerStatus.error);
      return false;
    }
  }

  /// Start the server
  Future<bool> startServer() async {
    if (_currentStatus == BareMetalServerStatus.running) {
      debugPrint('[BareMetalServerService] Server already running');
      return true;
    }

    _updateStatus(BareMetalServerStatus.starting);
    _lastError = null;

    try {
      // If venv not set up, run setup first
      if (!await isVenvSetup()) {
        debugPrint('[BareMetalServerService] Venv not found, running setup first');
        if (!await setupServer()) {
          return false;
        }
      }

      debugPrint('[BareMetalServerService] Starting server...');

      final result = await _runParachuteScript('start');
      if (result == null) {
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      if (result.exitCode == 0) {
        // Wait for server to be ready
        if (await _waitForServer()) {
          _updateStatus(BareMetalServerStatus.running);
          return true;
        } else {
          _lastError = 'Server started but not responding';
          _updateStatus(BareMetalServerStatus.error);
          return false;
        }
      } else {
        _lastError = result.stderr.toString();
        debugPrint('[BareMetalServerService] Start failed: $_lastError');
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error starting server: $e');
      _lastError = e.toString();
      _updateStatus(BareMetalServerStatus.error);
      return false;
    }
  }

  /// Stop the server
  Future<bool> stopServer() async {
    if (_currentStatus != BareMetalServerStatus.running) {
      return true;
    }

    _updateStatus(BareMetalServerStatus.stopping);

    try {
      debugPrint('[BareMetalServerService] Stopping server...');

      final result = await _runParachuteScript('stop');
      if (result == null) {
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      if (result.exitCode == 0) {
        _updateStatus(BareMetalServerStatus.stopped);
        return true;
      } else {
        _lastError = result.stderr.toString();
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error stopping server: $e');
      _lastError = e.toString();
      _updateStatus(BareMetalServerStatus.error);
      return false;
    }
  }

  /// Restart the server
  Future<bool> restartServer() async {
    _updateStatus(BareMetalServerStatus.starting);

    try {
      debugPrint('[BareMetalServerService] Restarting server...');

      final result = await _runParachuteScript('restart');
      if (result == null) {
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      if (result.exitCode == 0) {
        if (await _waitForServer()) {
          _updateStatus(BareMetalServerStatus.running);
          return true;
        }
      }

      _lastError = result.stderr.toString();
      _updateStatus(BareMetalServerStatus.error);
      return false;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error restarting server: $e');
      _lastError = e.toString();
      _updateStatus(BareMetalServerStatus.error);
      return false;
    }
  }

  /// Check if server is responding
  Future<bool> isServerHealthy() async {
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Get server version from health endpoint
  Future<String?> getServerVersion() async {
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['version'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error getting server version: $e');
      return null;
    }
  }

  /// Wait for server to be ready
  Future<bool> _waitForServer({int maxAttempts = 30}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (await isServerHealthy()) {
        debugPrint('[BareMetalServerService] Server is ready');
        return true;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    debugPrint('[BareMetalServerService] Server did not become ready');
    return false;
  }

  /// Run claude login (opens Terminal for interactive auth)
  Future<bool> runClaudeLogin() async {
    try {
      debugPrint('[BareMetalServerService] Running claude login...');

      // Open Terminal with claude login command
      if (Platform.isMacOS) {
        final script = 'tell application "Terminal" to do script "claude login"';
        await Process.run('osascript', ['-e', script]);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error running claude login: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Open a Terminal shell in the base directory
  Future<void> openShell() async {
    try {
      if (Platform.isMacOS) {
        final script = 'tell application "Terminal" to do script "cd \'$baseServerPath\' && source venv/bin/activate"';
        await Process.run('osascript', ['-e', script]);
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error opening shell: $e');
    }
  }

  // ============================================================
  // Auto-start (launchd) management
  // ============================================================

  static const String _launchdLabel = 'io.openparachute.server';

  /// Path to the launchd plist
  String get _launchdPlistPath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/LaunchAgents/$_launchdLabel.plist';
  }

  /// Check if auto-start is enabled
  Future<bool> isAutoStartEnabled() async {
    return File(_launchdPlistPath).exists();
  }

  /// Enable auto-start on login
  Future<bool> enableAutoStart() async {
    try {
      final plistContent = _generateLaunchdPlist();

      // Ensure LaunchAgents directory exists
      final launchAgentsDir = path.dirname(_launchdPlistPath);
      await Directory(launchAgentsDir).create(recursive: true);

      // Write plist
      await File(_launchdPlistPath).writeAsString(plistContent);

      // Load the agent
      await Process.run('launchctl', ['load', _launchdPlistPath]);

      debugPrint('[BareMetalServerService] Auto-start enabled');
      return true;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error enabling auto-start: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Disable auto-start on login
  Future<bool> disableAutoStart() async {
    try {
      if (await File(_launchdPlistPath).exists()) {
        // Unload the agent
        await Process.run('launchctl', ['unload', _launchdPlistPath]);

        // Remove plist
        await File(_launchdPlistPath).delete();
      }

      debugPrint('[BareMetalServerService] Auto-start disabled');
      return true;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error disabling auto-start: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Generate launchd plist content
  String _generateLaunchdPlist() {
    final home = Platform.environment['HOME'] ?? '';
    final scriptPath = path.join(baseServerPath, 'parachute.sh');

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_launchdLabel</string>

    <key>ProgramArguments</key>
    <array>
        <string>$scriptPath</string>
        <string>run</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$baseServerPath</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>VAULT_PATH</key>
        <string>$home</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/parachute-server.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/parachute-server.error.log</string>
</dict>
</plist>
''';
  }

  // ============================================================
  // Base server installation
  // ============================================================

  /// Install base server from app bundle
  Future<bool> installBaseServer() async {
    // Don't install if using custom path
    if (isUsingCustomPath) {
      debugPrint('[BareMetalServerService] Using custom path, skipping install');
      return true;
    }

    try {
      final destPath = _standardBasePath;

      // Check if already installed
      if (await Directory(destPath).exists()) {
        debugPrint('[BareMetalServerService] Base server already installed');
        return true;
      }

      // Find source in app bundle
      final executablePath = Platform.resolvedExecutable;
      final resourcesPath = path.join(
        path.dirname(executablePath),
        '../Resources/base',
      );

      if (!await Directory(resourcesPath).exists()) {
        _lastError = 'Base server not found in app bundle';
        return false;
      }

      // Create destination directory
      await Directory(path.dirname(destPath)).create(recursive: true);

      // Copy base server
      final result = await Process.run('cp', ['-R', resourcesPath, destPath]);
      if (result.exitCode != 0) {
        _lastError = 'Failed to copy base server: ${result.stderr}';
        return false;
      }

      debugPrint('[BareMetalServerService] Base server installed to $destPath');
      return true;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error installing base server: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Update status and notify listeners
  void _updateStatus(BareMetalServerStatus newStatus) {
    if (_currentStatus != newStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
      debugPrint('[BareMetalServerService] Status: $newStatus');
    }
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}
