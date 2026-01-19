import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Status of the Lima VM
enum LimaVMStatus {
  /// Lima not installed on system
  notInstalled,

  /// Lima installed but VM not created
  notCreated,

  /// VM exists but is stopped
  stopped,

  /// VM is starting up
  starting,

  /// VM is running
  running,

  /// VM is stopping
  stopping,

  /// Error state
  error,
}

/// Service for managing the Parachute Lima VM
///
/// This provides complete isolation for Claude Code - the VM's HOME
/// is set to the Parachute vault, so Claude can only access vault files.
class LimaVMService {
  static const String vmName = 'parachute';
  static const int serverPort = 3333;

  /// Version of base server bundled with this app
  /// This should match the version in base/parachute/__init__.py
  static const String bundledBaseVersion = '0.1.0';

  /// The vault path - must be set before using developer mode detection
  String? _vaultPath;

  /// Set the vault path (called by provider after FileSystemService initializes)
  void setVaultPath(String path) {
    _vaultPath = path;
  }

  LimaVMStatus _currentStatus = LimaVMStatus.notInstalled;
  String? _lastError;
  final _statusController = StreamController<LimaVMStatus>.broadcast();

  /// Stream of status changes
  Stream<LimaVMStatus> get statusStream => _statusController.stream;

  /// Current status
  LimaVMStatus get status => _currentStatus;

  /// Last error message if any
  String? get lastError => _lastError;

  /// Server URL when running
  String get serverUrl => 'http://localhost:$serverPort';

  /// Known paths where limactl might be installed
  static const List<String> _limactlPaths = [
    '/opt/homebrew/bin/limactl', // Apple Silicon Homebrew
    '/usr/local/bin/limactl', // Intel Homebrew
    '/usr/bin/limactl', // System path (unlikely)
  ];

  /// Get the path to limactl, or null if not found
  String? get limactlPath {
    for (final p in _limactlPaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }
    return null;
  }

  /// Check if Lima is installed
  /// Note: We check known paths directly because GUI apps don't inherit shell PATH
  Future<bool> isLimaInstalled() async {
    return limactlPath != null;
  }

  /// Run limactl with the given arguments
  /// Returns null if limactl is not installed
  Future<ProcessResult?> _runLimactl(List<String> args) async {
    final path = limactlPath;
    if (path == null) return null;
    return Process.run(path, args);
  }

  /// Check if the Parachute VM exists
  Future<bool> isVMCreated() async {
    try {
      final result = await _runLimactl(['list', '--json']);
      if (result == null || result.exitCode != 0) return false;

      final vms = _parseVMList(result.stdout.toString());
      return vms.any((vm) => vm['name'] == vmName);
    } catch (e) {
      debugPrint('[LimaVMService] Error checking VM: $e');
      return false;
    }
  }

  /// Parse limactl list --json output
  /// Output can be: empty, single JSON object, or newline-separated JSON objects
  List<Map<String, dynamic>> _parseVMList(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return [];

    final List<Map<String, dynamic>> vms = [];

    // Try parsing as newline-separated JSON objects
    for (final line in trimmed.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line.trim());
        if (decoded is Map<String, dynamic>) {
          vms.add(decoded);
        } else if (decoded is List) {
          // In case it's actually a list
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              vms.add(item);
            }
          }
        }
      } catch (e) {
        debugPrint('[LimaVMService] Failed to parse line: $line');
      }
    }

    return vms;
  }

  /// Get current VM status from limactl
  Future<LimaVMStatus> checkStatus() async {
    try {
      // Check if Lima is installed
      if (!await isLimaInstalled()) {
        _updateStatus(LimaVMStatus.notInstalled);
        return _currentStatus;
      }

      // Check if VM exists
      final result = await _runLimactl(['list', '--json']);
      if (result == null || result.exitCode != 0) {
        _updateStatus(LimaVMStatus.notCreated);
        return _currentStatus;
      }

      final vms = _parseVMList(result.stdout.toString());
      final vm = vms.cast<Map<String, dynamic>?>().firstWhere(
        (v) => v?['name'] == vmName,
        orElse: () => null,
      );

      if (vm == null) {
        _updateStatus(LimaVMStatus.notCreated);
        return _currentStatus;
      }

      // Check VM status
      final vmStatus = vm['status']?.toString().toLowerCase() ?? '';
      if (vmStatus == 'running') {
        _updateStatus(LimaVMStatus.running);
      } else if (vmStatus == 'stopped') {
        _updateStatus(LimaVMStatus.stopped);
      } else {
        _updateStatus(LimaVMStatus.stopped);
      }

      return _currentStatus;
    } catch (e) {
      debugPrint('[LimaVMService] Error checking status: $e');
      _lastError = e.toString();
      _updateStatus(LimaVMStatus.error);
      return _currentStatus;
    }
  }

  /// Get the path to the Lima config file
  String? _getLimaConfigPath() {
    // Look for config in the app bundle or in the vault
    final possiblePaths = [
      // In vault (for development)
      path.join(
        Platform.environment['HOME'] ?? '',
        'Parachute/projects/parachute/lima/parachute.yaml',
      ),
      // In app bundle
      path.join(
        path.dirname(Platform.resolvedExecutable),
        '../Resources/lima/parachute.yaml',
      ),
    ];

    for (final p in possiblePaths) {
      if (File(p).existsSync()) {
        return p;
      }
    }
    return null;
  }

  /// Create the VM (first-time setup)
  Future<bool> createVM() async {
    if (_currentStatus == LimaVMStatus.notInstalled) {
      _lastError = 'Lima is not installed. Run: brew install lima';
      return false;
    }

    final configPath = _getLimaConfigPath();
    if (configPath == null) {
      _lastError = 'Lima config file not found';
      _updateStatus(LimaVMStatus.error);
      return false;
    }

    _updateStatus(LimaVMStatus.starting);
    _lastError = null;

    try {
      debugPrint('[LimaVMService] Creating VM from: $configPath');

      final limaPath = limactlPath;
      if (limaPath == null) {
        _lastError = 'Lima is not installed';
        _updateStatus(LimaVMStatus.error);
        return false;
      }

      final process = await Process.start(
        limaPath,
        ['start', configPath],
        mode: ProcessStartMode.inheritStdio,
      );

      final exitCode = await process.exitCode;

      if (exitCode == 0) {
        _updateStatus(LimaVMStatus.running);
        return true;
      } else {
        _lastError = 'Failed to create VM (exit code: $exitCode)';
        _updateStatus(LimaVMStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error creating VM: $e');
      _lastError = e.toString();
      _updateStatus(LimaVMStatus.error);
      return false;
    }
  }

  /// Start the VM
  Future<bool> start() async {
    await checkStatus();

    if (_currentStatus == LimaVMStatus.notInstalled) {
      _lastError = 'Lima is not installed. Run: brew install lima';
      return false;
    }

    if (_currentStatus == LimaVMStatus.notCreated) {
      return createVM();
    }

    if (_currentStatus == LimaVMStatus.running) {
      debugPrint('[LimaVMService] VM already running');
      return true;
    }

    _updateStatus(LimaVMStatus.starting);
    _lastError = null;

    try {
      debugPrint('[LimaVMService] Starting VM...');

      final result = await _runLimactl(['start', vmName]);

      if (result != null && result.exitCode == 0) {
        _updateStatus(LimaVMStatus.running);

        // Wait for server to be ready
        await _waitForServer();

        return true;
      } else {
        _lastError = result?.stderr.toString() ?? 'Lima not installed';
        _updateStatus(LimaVMStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error starting VM: $e');
      _lastError = e.toString();
      _updateStatus(LimaVMStatus.error);
      return false;
    }
  }

  /// Stop the VM
  Future<bool> stop() async {
    if (_currentStatus != LimaVMStatus.running) {
      return true;
    }

    _updateStatus(LimaVMStatus.stopping);

    try {
      debugPrint('[LimaVMService] Stopping VM...');

      final result = await _runLimactl(['stop', vmName]);

      if (result != null && result.exitCode == 0) {
        _updateStatus(LimaVMStatus.stopped);
        return true;
      } else {
        _lastError = result?.stderr.toString() ?? 'Lima not installed';
        _updateStatus(LimaVMStatus.error);
        return false;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error stopping VM: $e');
      _lastError = e.toString();
      _updateStatus(LimaVMStatus.error);
      return false;
    }
  }

  /// Delete the VM completely
  Future<bool> delete() async {
    try {
      // Stop first if running
      if (_currentStatus == LimaVMStatus.running) {
        await stop();
      }

      debugPrint('[LimaVMService] Deleting VM...');

      final result = await _runLimactl(['delete', vmName, '--force']);

      if (result != null && result.exitCode == 0) {
        _updateStatus(LimaVMStatus.notCreated);
        return true;
      } else {
        _lastError = result?.stderr.toString() ?? 'Lima not installed';
        return false;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error deleting VM: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Get the base server path inside the VM
  /// Developer mode: ~/projects/parachute/base (via /vault mount)
  /// User mode: /opt/parachute/base (via Application Support mount)
  String get _vmBasePath {
    // Check host paths to determine which mode we're in
    final devPath = _developerBasePath;
    if (devPath != null && Directory(devPath).existsSync()) {
      return '~/projects/parachute/base';
    }
    return '/opt/parachute/base';
  }

  /// Start the Parachute server inside the VM
  Future<bool> startServer() async {
    if (_currentStatus != LimaVMStatus.running) {
      _lastError = 'VM is not running';
      return false;
    }

    try {
      final vmPath = _vmBasePath;
      debugPrint('[LimaVMService] Starting server in VM from $vmPath...');

      // Run server using parachute.sh script
      final result = await _runLimactl([
        'shell',
        '--workdir',
        '/vault',
        vmName,
        '--',
        'bash',
        '-c',
        'cd $vmPath && ./parachute.sh restart',
      ]);

      if (result != null && result.exitCode == 0) {
        // Wait for server to be ready
        return await _waitForServer();
      } else {
        _lastError = result?.stderr.toString() ?? 'Lima not installed';
        return false;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error starting server: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Check if the server is responding
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

  /// Wait for server to be ready
  Future<bool> _waitForServer({int maxAttempts = 30}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (await isServerHealthy()) {
        debugPrint('[LimaVMService] Server is ready');
        return true;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    debugPrint('[LimaVMService] Server did not become ready');
    return false;
  }

  /// Run Claude login inside the VM (opens in Terminal for interactive auth)
  Future<bool> runClaudeLogin() async {
    if (_currentStatus != LimaVMStatus.running) {
      _lastError = 'VM is not running';
      return false;
    }

    final limaPath = limactlPath;
    if (limaPath == null) {
      _lastError = 'Lima is not installed';
      return false;
    }

    try {
      debugPrint('[LimaVMService] Running claude login in VM...');

      // Claude login needs interactive terminal, so open in Terminal.app
      // Use --workdir /vault to avoid "cd: /Users/...: No such file" errors
      if (Platform.isMacOS) {
        final script = 'tell application "Terminal" to do script "$limaPath shell --workdir /vault $vmName -- claude login"';
        await Process.run('osascript', ['-e', script]);
        return true;
      } else {
        // For Linux, try xterm or similar
        final result = await _runLimactl(
          ['shell', '--workdir', '/vault', vmName, '--', 'claude', 'login'],
        );
        return result != null && result.exitCode == 0;
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error running claude login: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Open a shell to the VM
  Future<void> openShell() async {
    if (_currentStatus != LimaVMStatus.running) {
      debugPrint('[LimaVMService] VM is not running');
      return;
    }

    final limaPath = limactlPath;
    if (limaPath == null) {
      debugPrint('[LimaVMService] Lima is not installed');
      return;
    }

    try {
      // Open Terminal with limactl shell command (specifying our VM name)
      // Use --workdir /vault to start in the vault directory
      if (Platform.isMacOS) {
        final script = 'tell application "Terminal" to do script "$limaPath shell --workdir /vault $vmName"';
        await Process.run('osascript', ['-e', script]);
      }
    } catch (e) {
      debugPrint('[LimaVMService] Error opening shell: $e');
    }
  }

  /// Update status and notify listeners
  void _updateStatus(LimaVMStatus newStatus) {
    if (_currentStatus != newStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
      debugPrint('[LimaVMService] Status: $newStatus');
    }
  }

  // ============================================================
  // Auto-start (launchd) management
  // ============================================================

  static const String _launchdLabel = 'io.openparachute.vm';

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
      // Find the plist template in app bundle or vault
      final plistContent = _generateLaunchdPlist();

      // Ensure LaunchAgents directory exists
      final launchAgentsDir = path.dirname(_launchdPlistPath);
      await Directory(launchAgentsDir).create(recursive: true);

      // Write plist
      await File(_launchdPlistPath).writeAsString(plistContent);

      // Load the agent
      await Process.run('launchctl', ['load', _launchdPlistPath]);

      debugPrint('[LimaVMService] Auto-start enabled');
      return true;
    } catch (e) {
      debugPrint('[LimaVMService] Error enabling auto-start: $e');
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

      debugPrint('[LimaVMService] Auto-start disabled');
      return true;
    } catch (e) {
      debugPrint('[LimaVMService] Error disabling auto-start: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Generate launchd plist content
  String _generateLaunchdPlist() {
    // Find limactl path
    const limactlPath = '/opt/homebrew/bin/limactl';

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_launchdLabel</string>

    <key>ProgramArguments</key>
    <array>
        <string>$limactlPath</string>
        <string>start</string>
        <string>$vmName</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/tmp/parachute-vm.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/parachute-vm.error.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
''';
  }

  // ============================================================
  // Base server installation
  // ============================================================

  /// Path where developers keep base (in the vault, as a git repo)
  /// Returns null if vault path not set
  String? get _developerBasePath {
    if (_vaultPath == null) return null;
    return '$_vaultPath/projects/parachute/base';
  }

  /// Path where regular users' base is installed (hidden from vault)
  static String get _userBasePath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Application Support/Parachute/base';
  }

  /// Get the active base server path
  /// Prefers developer path if it exists (has .git), otherwise uses user path
  String get baseServerPath {
    final devPath = _developerBasePath;
    if (devPath != null) {
      // Check if developer path exists with .git (active development)
      if (Directory('$devPath/.git').existsSync()) {
        return devPath;
      }
      // Check if developer path exists at all (manual setup)
      if (Directory(devPath).existsSync()) {
        return devPath;
      }
    }
    // Default to user path
    return _userBasePath;
  }

  /// Check if we're in developer mode (base in vault as git repo)
  bool get isDeveloperMode {
    final devPath = _developerBasePath;
    if (devPath == null) return false;
    return Directory('$devPath/.git').existsSync();
  }

  /// Check if base server is installed (in either location)
  Future<bool> isBaseServerInstalled() async {
    return Directory(baseServerPath).exists();
  }

  /// Install base server from app bundle
  /// Installs to user path (~/Library/Application Support/Parachute/base/)
  /// unless developer path already exists
  Future<bool> installBaseServer() async {
    try {
      // If developer path exists, don't overwrite it
      final devPath = _developerBasePath;
      if (devPath != null && await Directory(devPath).exists()) {
        debugPrint('[LimaVMService] Developer base exists, skipping install');
        return true;
      }

      final destPath = _userBasePath;

      // Check if already installed
      if (await Directory(destPath).exists()) {
        debugPrint('[LimaVMService] Base server already installed');
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

      debugPrint('[LimaVMService] Base server installed to $destPath');
      return true;
    } catch (e) {
      debugPrint('[LimaVMService] Error installing base server: $e');
      _lastError = e.toString();
      return false;
    }
  }

  // ============================================================
  // Base server version management
  // ============================================================

  /// Get the running server's version from the health endpoint
  /// Returns null if server is not responding or version unavailable
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
      debugPrint('[LimaVMService] Error getting server version: $e');
      return null;
    }
  }

  /// Check if the running server needs an update
  /// Returns true if bundled version is newer than running version
  Future<bool> isBaseUpdateAvailable() async {
    final serverVersion = await getServerVersion();
    if (serverVersion == null) return false;

    return _compareVersions(bundledBaseVersion, serverVersion) > 0;
  }

  /// Compare two semantic versions
  /// Returns: positive if a > b, negative if a < b, 0 if equal
  int _compareVersions(String a, String b) {
    final aParts = a.split('.').map(int.parse).toList();
    final bParts = b.split('.').map(int.parse).toList();

    for (var i = 0; i < 3; i++) {
      final aPart = i < aParts.length ? aParts[i] : 0;
      final bPart = i < bParts.length ? bParts[i] : 0;
      if (aPart != bPart) return aPart - bPart;
    }
    return 0;
  }

  /// Update the base server from the app bundle
  /// This replaces the existing base with the bundled version
  /// NOTE: In developer mode, this is a no-op (developers manage their own base)
  Future<bool> updateBaseServer() async {
    // Don't update in developer mode - they manage their own base via git
    if (isDeveloperMode) {
      debugPrint('[LimaVMService] Developer mode - skipping base update');
      return true;
    }

    try {
      final destPath = _userBasePath;

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

      // Back up current version (keep venv)
      final backupPath = '$destPath.backup';
      if (await Directory(destPath).exists()) {
        // Remove old backup if exists
        if (await Directory(backupPath).exists()) {
          await Directory(backupPath).delete(recursive: true);
        }

        // Move current to backup (preserves venv)
        await Directory(destPath).rename(backupPath);
        debugPrint('[LimaVMService] Backed up current base to $backupPath');
      }

      // Copy new base
      final result = await Process.run('cp', ['-R', resourcesPath, destPath]);
      if (result.exitCode != 0) {
        // Restore backup on failure
        if (await Directory(backupPath).exists()) {
          await Directory(backupPath).rename(destPath);
        }
        _lastError = 'Failed to copy base server: ${result.stderr}';
        return false;
      }

      // Copy venv from backup if it exists (avoid re-creating)
      final backupVenv = '$backupPath/venv';
      final destVenv = '$destPath/venv';
      if (await Directory(backupVenv).exists()) {
        await Process.run('cp', ['-R', backupVenv, destVenv]);
        debugPrint('[LimaVMService] Preserved venv from backup');
      }

      // Clean up backup
      if (await Directory(backupPath).exists()) {
        await Directory(backupPath).delete(recursive: true);
      }

      debugPrint('[LimaVMService] Base server updated to $bundledBaseVersion');

      // Restart server to pick up changes
      if (_currentStatus == LimaVMStatus.running) {
        await startServer();
      }

      return true;
    } catch (e) {
      debugPrint('[LimaVMService] Error updating base server: $e');
      _lastError = e.toString();
      return false;
    }
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}
