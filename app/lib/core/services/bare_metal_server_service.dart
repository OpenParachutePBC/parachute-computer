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

  /// Version of Parachute Computer bundled with this app
  /// This should match the version in base/parachute/__init__.py
  static const String bundledBaseVersion = '0.1.0';

  /// Minimum Python version required
  static const String minPythonVersion = '3.10';

  /// Maximum Python version supported (3.14+ doesn't have all packages yet)
  static const String maxPythonVersion = '3.13';

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

  /// Standard computer path in Application Support
  static String get _standardBasePath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Application Support/Parachute/base';
  }

  /// Get the active computer path
  /// Returns custom path if set, otherwise standard path
  String get computerPath {
    return _customBasePath ?? _standardBasePath;
  }

  /// Whether using a custom (developer) base path
  bool get isUsingCustomPath => _customBasePath != null;

  /// Known paths where Python might be installed
  /// Includes versioned paths for Homebrew installations
  static const List<String> _pythonPaths = [
    '/opt/homebrew/bin/python3.13', // Homebrew Apple Silicon (versioned)
    '/opt/homebrew/bin/python3.12', // Homebrew Apple Silicon (versioned)
    '/opt/homebrew/bin/python3.11', // Homebrew Apple Silicon (versioned)
    '/opt/homebrew/bin/python3.10', // Homebrew Apple Silicon (versioned)
    '/opt/homebrew/bin/python3', // Homebrew Apple Silicon (generic)
    '/usr/local/bin/python3.13', // Homebrew Intel (versioned)
    '/usr/local/bin/python3.12', // Homebrew Intel (versioned)
    '/usr/local/bin/python3.11', // Homebrew Intel (versioned)
    '/usr/local/bin/python3.10', // Homebrew Intel (versioned)
    '/usr/local/bin/python3', // Homebrew Intel (generic)
    '/usr/bin/python3', // System Python (last resort)
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

  /// Check if Python 3.10-3.13 is installed
  /// Returns true if a compatible version is found
  /// Note: Python 3.14+ is too new and doesn't have all required packages
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

      // Require 3.10-3.13 (3.14+ doesn't have all packages yet)
      if (major != 3) return false;
      return minor >= 10 && minor <= 13;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error checking Python: $e');
      return false;
    }
  }

  /// Get detailed Python version info for error messages
  Future<(bool isCompatible, String? version, String? reason)> checkPythonCompatibility() async {
    final python = pythonPath;
    if (python == null) {
      return (false, null, 'Python not found. Install Python 3.10-3.13 via Homebrew.');
    }

    try {
      final result = await Process.run(python, ['--version']);
      if (result.exitCode != 0) {
        return (false, null, 'Could not determine Python version.');
      }

      final output = result.stdout.toString().trim();
      final match = RegExp(r'Python (\d+)\.(\d+)').firstMatch(output);
      if (match == null) {
        return (false, output, 'Could not parse Python version.');
      }

      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);

      if (major != 3) {
        return (false, output, 'Python 3 required (found Python $major).');
      }

      if (minor < 10) {
        return (false, output, 'Python 3.10+ required (found 3.$minor). Run: brew install python@3.13 && brew link python@3.13');
      }

      if (minor > 13) {
        return (false, output, 'Python 3.$minor is too new - packages not available yet. Install 3.13: brew install python@3.13 && brew link python@3.13');
      }

      return (true, output, null);
    } catch (e) {
      return (false, null, 'Error checking Python: $e');
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

  /// Check if Parachute Computer is installed (has parachute.sh)
  Future<bool> isServerInstalled() async {
    final scriptPath = path.join(computerPath, 'parachute.sh');
    return File(scriptPath).exists();
  }

  /// Check if venv is set up (python exists)
  Future<bool> isVenvSetup() async {
    final venvPython = path.join(computerPath, 'venv', 'bin', 'python');
    return File(venvPython).exists();
  }

  /// Check if dependencies are installed (uvicorn exists in venv)
  Future<bool> areDependenciesInstalled() async {
    final uvicornPath = path.join(computerPath, 'venv', 'bin', 'uvicorn');
    return File(uvicornPath).exists();
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
  Future<ProcessResult?> _runParachuteScript(String command, {String? vaultPath}) async {
    final scriptPath = path.join(computerPath, 'parachute.sh');
    if (!await File(scriptPath).exists()) {
      _lastError = 'parachute.sh not found at $scriptPath';
      return null;
    }

    try {
      // Pass the validated Python path to ensure the script uses the same version
      // we validated in the setup wizard (avoids using wrong Python from PATH)
      final python = pythonPath;

      // Build environment with proper PATH for finding Python and other tools
      final env = _environmentWithPath;
      env['VAULT_PATH'] = vaultPath ?? Platform.environment['HOME'] ?? '';
      if (python != null) {
        env['PYTHON_PATH'] = python;
      }

      debugPrint('[BareMetalServerService] Running: parachute.sh $command');
      debugPrint('[BareMetalServerService] PYTHON_PATH: $python');
      debugPrint('[BareMetalServerService] VAULT_PATH: ${env['VAULT_PATH']}');

      return await Process.run(
        'bash',
        [scriptPath, command],
        workingDirectory: computerPath,
        environment: env,
      );
    } catch (e) {
      _lastError = 'Error running parachute.sh: $e';
      return null;
    }
  }

  /// Set up the server (create venv, install dependencies)
  Future<bool> setupServer() async {
    _updateStatus(BareMetalServerStatus.starting);

    try {
      // Check if server is installed first
      if (!await isServerInstalled()) {
        _lastError = 'Server not installed. Please install Parachute Computer first.';
        debugPrint('[BareMetalServerService] $_lastError');
        _updateStatus(BareMetalServerStatus.notInstalled);
        return false;
      }

      debugPrint('[BareMetalServerService] Running setup...');
      debugPrint('[BareMetalServerService] Base path: $computerPath');

      final result = await _runParachuteScript('setup');
      if (result == null) {
        // _runParachuteScript sets _lastError
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      debugPrint('[BareMetalServerService] parachute.sh setup exited with ${result.exitCode}');
      debugPrint('[BareMetalServerService] stdout: ${result.stdout}');
      debugPrint('[BareMetalServerService] stderr: ${result.stderr}');

      if (result.exitCode == 0) {
        debugPrint('[BareMetalServerService] Setup complete');
        _updateStatus(BareMetalServerStatus.stopped);
        return true;
      } else {
        final stderr = result.stderr.toString().trim();
        final stdout = result.stdout.toString().trim();
        _lastError = stderr.isNotEmpty ? stderr : (stdout.isNotEmpty ? stdout : 'Setup failed (exit code ${result.exitCode})');
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

    try {
      // Check if server is installed
      if (!await isServerInstalled()) {
        _lastError = 'Server not installed. Run setup first.';
        debugPrint('[BareMetalServerService] $_lastError');
        _updateStatus(BareMetalServerStatus.notInstalled);
        return false;
      }

      // If venv not set up or dependencies missing, run setup first
      final venvExists = await isVenvSetup();
      final depsInstalled = await areDependenciesInstalled();

      if (!venvExists || !depsInstalled) {
        debugPrint('[BareMetalServerService] Venv exists: $venvExists, deps installed: $depsInstalled - running setup');
        if (!await setupServer()) {
          // setupServer sets _lastError, preserve it
          _updateStatus(BareMetalServerStatus.error);
          return false;
        }
      }

      debugPrint('[BareMetalServerService] Starting server...');

      final result = await _runParachuteScript('start');
      if (result == null) {
        // _runParachuteScript sets _lastError when returning null
        _updateStatus(BareMetalServerStatus.error);
        return false;
      }

      debugPrint('[BareMetalServerService] parachute.sh start exited with ${result.exitCode}');
      debugPrint('[BareMetalServerService] stdout: ${result.stdout}');
      debugPrint('[BareMetalServerService] stderr: ${result.stderr}');

      if (result.exitCode == 0) {
        // Wait for server to be ready
        if (await _waitForServer()) {
          _updateStatus(BareMetalServerStatus.running);
          return true;
        } else {
          _lastError = 'Server started but not responding on port $serverPort';
          _updateStatus(BareMetalServerStatus.error);
          return false;
        }
      } else {
        final stderr = result.stderr.toString().trim();
        final stdout = result.stdout.toString().trim();
        _lastError = stderr.isNotEmpty ? stderr : (stdout.isNotEmpty ? stdout : 'Unknown error (exit code ${result.exitCode})');
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

  /// Known paths where Claude CLI might be installed
  static const List<String> _claudePaths = [
    '/opt/homebrew/bin/claude', // Homebrew Apple Silicon
    '/usr/local/bin/claude', // Homebrew Intel / npm global
    // npm global paths vary by Node installation
  ];

  /// Get the path to Claude CLI, or null if not found
  Future<String?> get claudePath async {
    // Check known paths first
    for (final p in _claudePaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }

    // Try to find via 'which' command
    try {
      final result = await Process.run('which', ['claude']);
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty && File(path).existsSync()) {
          return path;
        }
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error finding claude: $e');
    }

    return null;
  }

  /// Check if Claude CLI is installed
  Future<bool> isClaudeInstalled() async {
    return await claudePath != null;
  }

  /// Get Claude CLI version if installed
  Future<String?> getClaudeVersion() async {
    final path = await claudePath;
    if (path == null) return null;

    try {
      final result = await Process.run(path, ['--version']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error getting claude version: $e');
    }
    return null;
  }

  /// Known paths where Node.js/npm might be installed (macOS)
  static const List<String> _npmPaths = [
    '/opt/homebrew/bin/npm', // Homebrew Apple Silicon
    '/usr/local/bin/npm', // Homebrew Intel
  ];

  /// Check if Node.js/npm is installed by checking explicit paths first
  Future<bool> isNodeInstalled() async {
    // Check explicit paths first (most reliable)
    for (final p in _npmPaths) {
      if (File(p).existsSync()) {
        return true;
      }
    }

    // Fall back to which command with proper PATH
    try {
      final result = await Process.run(
        'which',
        ['npm'],
        environment: _environmentWithPath,
      );
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Environment with Homebrew paths added to PATH
  /// This ensures brew/npm/node are found when running subprocesses
  Map<String, String> get _environmentWithPath {
    final env = Map<String, String>.from(Platform.environment);
    final currentPath = env['PATH'] ?? '';
    // Prepend Homebrew paths to ensure they're found
    env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:$currentPath';
    return env;
  }

  /// Get the path to brew, or null if not found
  String? get brewPath {
    const brewPaths = [
      '/opt/homebrew/bin/brew', // Apple Silicon
      '/usr/local/bin/brew', // Intel
    ];
    for (final p in brewPaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }
    return null;
  }

  /// Install Node.js via Homebrew (macOS only)
  ///
  /// This runs `brew install node` which can take 1-3 minutes depending on
  /// network speed and whether dependencies need to be built.
  ///
  /// Returns (success, errorMessage)
  Future<(bool, String?)> installNode() async {
    try {
      debugPrint('[BareMetalServerService] Installing Node.js via Homebrew...');

      final brew = brewPath;
      if (brew == null) {
        return (false, 'Homebrew not found. Please install Homebrew first.');
      }

      // brew install can take several minutes, especially on first install
      // or if dependencies need to be built from source
      final result = await Process.run(
        brew,
        ['install', 'node'],
        environment: _environmentWithPath,
      ).timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          debugPrint('[BareMetalServerService] brew install node timed out after 10 minutes');
          return ProcessResult(-1, -1, '', 'Installation timed out after 10 minutes. Try running "brew install node" manually in Terminal.');
        },
      );

      debugPrint('[BareMetalServerService] brew install node exited with ${result.exitCode}');
      debugPrint('[BareMetalServerService] stdout: ${result.stdout}');
      debugPrint('[BareMetalServerService] stderr: ${result.stderr}');

      if (result.exitCode == 0) {
        return (true, null);
      } else {
        final stderr = result.stderr.toString().trim();
        final stdout = result.stdout.toString().trim();
        // Check if it's already installed (brew returns non-zero for this)
        if (stdout.contains('already installed') || stderr.contains('already installed')) {
          return (true, null);
        }
        // Provide helpful error message
        final errorMsg = stderr.isNotEmpty ? stderr : stdout;
        return (false, errorMsg.isNotEmpty ? errorMsg : 'Installation failed with exit code ${result.exitCode}');
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error installing Node.js: $e');
      return (false, e.toString());
    }
  }

  /// Get the path to npm, or null if not found
  Future<String?> get npmPath async {
    // Check explicit paths first (most reliable)
    for (final p in _npmPaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }

    // Try to find via 'which' command with proper PATH
    try {
      final result = await Process.run(
        'which',
        ['npm'],
        environment: _environmentWithPath,
      );
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty && File(path).existsSync()) {
          return path;
        }
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error finding npm: $e');
    }

    return null;
  }

  /// Install Claude CLI via npm (non-interactive, macOS only)
  ///
  /// This runs `npm install -g @anthropic-ai/claude-code` which typically
  /// takes 30-60 seconds depending on network speed.
  ///
  /// Note: May require sudo on some systems if npm global directory isn't writable.
  /// Homebrew-installed npm typically doesn't need sudo.
  ///
  /// Returns (success, errorMessage)
  Future<(bool, String?)> installClaudeCLINonInteractive() async {
    try {
      debugPrint('[BareMetalServerService] Installing Claude CLI via npm...');

      final npm = await npmPath;
      if (npm == null) {
        return (false, 'npm not found. Please install Node.js first.');
      }

      // npm global installs typically take 30-60 seconds
      final result = await Process.run(
        npm,
        ['install', '-g', '@anthropic-ai/claude-code'],
        environment: _environmentWithPath,
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          debugPrint('[BareMetalServerService] npm install timed out after 5 minutes');
          return ProcessResult(-1, -1, '', 'Installation timed out after 5 minutes. Try running "npm install -g @anthropic-ai/claude-code" manually in Terminal.');
        },
      );

      debugPrint('[BareMetalServerService] npm install exited with ${result.exitCode}');
      debugPrint('[BareMetalServerService] stdout: ${result.stdout}');
      debugPrint('[BareMetalServerService] stderr: ${result.stderr}');

      if (result.exitCode == 0) {
        return (true, null);
      } else {
        final stderr = result.stderr.toString().trim();
        final stdout = result.stdout.toString().trim();
        // Check for permission errors
        if (stderr.contains('EACCES') || stderr.contains('permission denied')) {
          return (false, 'Permission denied. Try running in Terminal:\nsudo npm install -g @anthropic-ai/claude-code');
        }
        final errorMsg = stderr.isNotEmpty ? stderr : stdout;
        return (false, errorMsg.isNotEmpty ? errorMsg : 'Installation failed with exit code ${result.exitCode}');
      }
    } catch (e) {
      debugPrint('[BareMetalServerService] Error installing Claude CLI: $e');
      return (false, e.toString());
    }
  }

  /// Run claude login (opens Terminal for interactive auth)
  ///
  /// If [vaultPath] is provided, sets HOME to the vault path so credentials
  /// are stored in {vault}/.claude/ making the vault fully self-contained
  /// and portable across machines.
  Future<bool> runClaudeLogin({String? vaultPath}) async {
    try {
      debugPrint('[BareMetalServerService] Running claude login (vault: $vaultPath)...');

      // Open Terminal with claude login command
      if (Platform.isMacOS) {
        String command;
        if (vaultPath != null && vaultPath.isNotEmpty) {
          // Self-contained mode: store credentials in vault
          // Use single quotes around the path to handle spaces
          command = "HOME='$vaultPath' claude login";
        } else {
          // Standard mode: use system-wide credentials
          command = 'claude login';
        }
        final script = 'tell application "Terminal" to do script "$command"';
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

  /// Install Claude CLI via npm (opens Terminal)
  ///
  /// If [vaultPath] is provided, sets HOME to the vault path so credentials
  /// are stored in {vault}/.claude/ making the vault fully self-contained.
  Future<bool> installClaudeCLI({String? vaultPath}) async {
    try {
      debugPrint('[BareMetalServerService] Installing Claude CLI (vault: $vaultPath)...');

      if (Platform.isMacOS) {
        // Install globally via npm, then run claude login
        String loginCmd;
        if (vaultPath != null && vaultPath.isNotEmpty) {
          // Use single quotes around the path to handle spaces
          loginCmd = "HOME='$vaultPath' claude login";
        } else {
          loginCmd = 'claude login';
        }
        final script = 'tell application "Terminal" to do script "npm install -g @anthropic-ai/claude-code && $loginCmd"';
        await Process.run('osascript', ['-e', script]);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error installing Claude CLI: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Open a Terminal shell in the base directory
  Future<void> openShell() async {
    try {
      if (Platform.isMacOS) {
        final script = 'tell application "Terminal" to do script "cd \'$computerPath\' && source venv/bin/activate"';
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
    final scriptPath = path.join(computerPath, 'parachute.sh');

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
    <string>$computerPath</string>

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
  // Parachute Computer installation
  // ============================================================

  /// Install Parachute Computer from app bundle
  Future<bool> installComputer() async {
    // Don't install if using custom path
    if (isUsingCustomPath) {
      debugPrint('[BareMetalServerService] Using custom path, skipping install');
      return true;
    }

    try {
      final destPath = _standardBasePath;

      // Check if already installed
      if (await Directory(destPath).exists()) {
        debugPrint('[BareMetalServerService] Parachute Computer already installed');
        return true;
      }

      // Find source in app bundle
      final executablePath = Platform.resolvedExecutable;
      final resourcesPath = path.join(
        path.dirname(executablePath),
        '../Resources/base',
      );

      if (!await Directory(resourcesPath).exists()) {
        _lastError = 'Parachute Computer not found in app bundle';
        return false;
      }

      // Create destination directory
      await Directory(path.dirname(destPath)).create(recursive: true);

      // Copy Parachute Computer
      final result = await Process.run('cp', ['-R', resourcesPath, destPath]);
      if (result.exitCode != 0) {
        _lastError = 'Failed to copy Parachute Computer: ${result.stderr}';
        return false;
      }

      debugPrint('[BareMetalServerService] Parachute Computer installed to $destPath');
      return true;
    } catch (e) {
      debugPrint('[BareMetalServerService] Error installing Parachute Computer: $e');
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
