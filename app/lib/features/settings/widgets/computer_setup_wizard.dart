import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/lima_vm_provider.dart';
import 'package:parachute/core/providers/bare_metal_provider.dart';
import 'package:parachute/core/services/lima_vm_service.dart';
import 'package:parachute/core/services/bare_metal_server_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Setup wizard for Parachute Computer
///
/// Guides users through setup with two paths:
///
/// **Lima VM Path (isolated):**
/// 1. Choose setup mode
/// 2. Install Homebrew (if needed)
/// 3. Install Lima (if needed)
/// 4. Create and start VM
/// 5. Authenticate with Claude
///
/// **Bare Metal Path (direct):**
/// 1. Choose setup mode
/// 2. Check Python
/// 3. Install/setup server
/// 4. Authenticate with Claude
/// 5. Enable auto-start
class ComputerSetupWizard extends ConsumerStatefulWidget {
  final VoidCallback? onComplete;

  const ComputerSetupWizard({super.key, this.onComplete});

  @override
  ConsumerState<ComputerSetupWizard> createState() => _ComputerSetupWizardState();
}

class _ComputerSetupWizardState extends ConsumerState<ComputerSetupWizard> {
  // Vault path selection
  String? _selectedVaultPath;
  bool _vaultPathSelected = false;

  // Mode selection (null = not yet chosen)
  ServerMode? _selectedMode;

  // Current step within the selected path
  int _currentStep = 0;

  bool _isLoading = false;
  String? _error;

  // Lima VM path state
  bool _homebrewInstalled = false;
  bool _limaInstalled = false;
  String? _vmProgressMessage;

  // Bare metal path state
  bool _pythonInstalled = false;
  String? _pythonVersion;
  bool _serverInstalled = false;
  bool _claudeInstalled = false;
  bool _nodeInstalled = false;
  String? _setupProgressMessage;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  /// Load previously saved settings (vault path and mode)
  Future<void> _loadSavedSettings() async {
    // Load saved vault path
    final savedVaultPath = await ref.read(vaultPathProvider.future);
    if (savedVaultPath != null && savedVaultPath.isNotEmpty) {
      setState(() {
        _selectedVaultPath = savedVaultPath;
        _vaultPathSelected = true;
      });
    } else {
      // Default to ~/Parachute
      final home = Platform.environment['HOME'] ?? '';
      setState(() {
        _selectedVaultPath = '$home/Parachute';
      });
    }
  }

  /// Get the home directory path
  String get _homePath => Platform.environment['HOME'] ?? '';

  /// Default vault path options
  List<({String path, String label, String description})> get _vaultPathOptions => [
    (
      path: '$_homePath/Parachute',
      label: '~/Parachute',
      description: 'Dedicated folder for all your Parachute data. Recommended for most users.',
    ),
    (
      path: _homePath,
      label: 'Home Directory (~)',
      description: 'Use your entire home folder as the vault. Claude can access all your files.',
    ),
  ];

  /// Check prerequisites for the selected mode
  Future<void> _checkPrerequisites() async {
    if (_selectedMode == null) return;

    setState(() => _isLoading = true);

    try {
      if (_selectedMode == ServerMode.limaVM) {
        await _checkLimaPrerequisites();
      } else {
        await _checkBareMetalPrerequisites();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _checkLimaPrerequisites() async {
    // Check Homebrew
    _homebrewInstalled = _brewPaths.any((p) => File(p).existsSync());

    // Check Lima
    final limaService = ref.read(limaVMServiceProvider);
    _limaInstalled = await limaService.isLimaInstalled();

    // Determine starting step
    if (!_homebrewInstalled) {
      _currentStep = 0;
    } else if (!_limaInstalled) {
      _currentStep = 1;
    } else {
      _currentStep = 2;
    }
  }

  Future<void> _checkBareMetalPrerequisites() async {
    final service = ref.read(bareMetalServiceProvider);

    _pythonInstalled = await service.isPythonInstalled();
    _pythonVersion = await service.getPythonVersion();
    _serverInstalled = await service.isServerInstalled();
    _claudeInstalled = await service.isClaudeInstalled();
    _nodeInstalled = await service.isNodeInstalled();

    // Determine starting step
    if (!_pythonInstalled) {
      _currentStep = 0;
    } else if (!_serverInstalled) {
      _currentStep = 1;
    } else if (!_claudeInstalled) {
      _currentStep = 2;
    } else {
      _currentStep = 3; // Claude auth step
    }
  }

  /// Select a mode and save it
  Future<void> _selectMode(ServerMode mode) async {
    setState(() {
      _selectedMode = mode;
      _currentStep = 0;
      _error = null;
    });

    // Save the mode
    await ref.read(serverModeProvider.notifier).setServerMode(mode);

    // Check prerequisites
    await _checkPrerequisites();
  }

  // ============================================================
  // Lima VM Path Methods
  // ============================================================

  static const List<String> _brewPaths = [
    '/opt/homebrew/bin/brew', // Apple Silicon
    '/usr/local/bin/brew', // Intel
  ];

  String? get _brewPath {
    for (final p in _brewPaths) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  Future<void> _installHomebrew() async {
    final url = Uri.parse('https://brew.sh');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Install Homebrew'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Run this command in Terminal:'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: SelectableText(
                        '/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(const ClipboardData(
                          text: '/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
                        ));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('After installation, click "Check Again" below.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _checkPrerequisites();
              },
              child: const Text('Check Again'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _installLima() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final brewPath = _brewPath;
      if (brewPath == null) {
        _error = 'Homebrew not found. Please install Homebrew first.';
        return;
      }

      final result = await Process.run(brewPath, ['install', 'lima']);

      if (result.exitCode == 0) {
        setState(() => _limaInstalled = true);
        _currentStep = 2;
      } else {
        _error = 'Failed to install Lima: ${result.stderr}';
      }
    } catch (e) {
      _error = 'Error installing Lima: $e';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _createAndStartVM() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _vmProgressMessage = 'Preparing...';
    });

    try {
      final service = await ref.read(limaVMServiceInitializedProvider.future);

      // Install base server if needed
      if (!await service.isBaseServerInstalled()) {
        if (mounted) {
          setState(() => _vmProgressMessage = 'Installing base server...');
        }
        final installed = await service.installBaseServer();
        if (!installed) {
          _error = service.lastError ?? 'Failed to install base server';
          return;
        }
      }

      // Create/start the VM
      if (mounted) {
        setState(() => _vmProgressMessage = 'Downloading Ubuntu & creating VM...');
      }
      final success = await service.start();

      if (success) {
        if (mounted) {
          setState(() => _vmProgressMessage = 'Starting server...');
        }
        await service.startServer();
        _currentStep = 3;
      } else {
        _error = service.lastError ?? 'Failed to create VM';
      }
    } catch (e) {
      _error = 'Error creating VM: $e';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _vmProgressMessage = null;
        });
      }
    }
  }

  Future<void> _authenticateClaudeLima() async {
    final service = ref.read(limaVMServiceProvider);
    await service.runClaudeLogin();
    setState(() => _currentStep = 4);
  }

  // ============================================================
  // Bare Metal Path Methods
  // ============================================================

  Future<void> _installPython() async {
    // Open Python download page
    final url = Uri.parse('https://www.python.org/downloads/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Install Python'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Python 3.10-3.13 is required.'),
              const SizedBox(height: 8),
              Text(
                'Note: Python 3.14+ is too new and doesn\'t have all required packages yet.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              const Text('Install via Homebrew:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: SelectableText(
                        'brew install python@3.13',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(const ClipboardData(text: 'brew install python@3.13'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('Then make it your default:'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: SelectableText(
                        'brew link python@3.13',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(const ClipboardData(text: 'brew link python@3.13'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('After installation, click "Check Again" below.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _checkPrerequisites();
              },
              child: const Text('Check Again'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _setupBareMetalServer() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _setupProgressMessage = 'Installing server...';
    });

    String currentStep = 'initializing';

    try {
      final service = ref.read(bareMetalServiceProvider);

      // Step 1: Install base server from bundle
      currentStep = 'copying server files';
      if (!await service.isServerInstalled()) {
        if (mounted) {
          setState(() => _setupProgressMessage = 'Copying server files...');
        }
        final installed = await service.installBaseServer();
        if (!installed) {
          _error = 'Failed while $currentStep: ${service.lastError ?? 'Unknown error'}';
          return;
        }
      }

      // Step 2: Set up venv and install dependencies
      currentStep = 'installing Python dependencies';
      if (mounted) {
        setState(() => _setupProgressMessage = 'Installing dependencies (this may take a minute)...');
      }
      final setup = await service.setupServer();
      if (!setup) {
        _error = 'Failed while $currentStep: ${service.lastError ?? 'Unknown error'}';
        return;
      }

      // Step 3: Start the server
      currentStep = 'starting server';
      if (mounted) {
        setState(() => _setupProgressMessage = 'Starting server...');
      }
      final started = await service.startServer();
      if (!started) {
        _error = 'Failed while $currentStep: ${service.lastError ?? 'Unknown error'}';
        return;
      }

      // Step 4: Verify server is healthy
      currentStep = 'verifying server health';
      if (mounted) {
        setState(() => _setupProgressMessage = 'Verifying server is responding...');
      }
      final healthy = await service.isServerHealthy();
      if (!healthy) {
        _error = 'Server started but is not responding. Check logs at /tmp/parachute-server.log';
        return;
      }

      _serverInstalled = true;
      _currentStep = 2;
    } catch (e) {
      _error = 'Error while $currentStep: $e';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _setupProgressMessage = null;
        });
      }
    }
  }

  Future<void> _authenticateClaudeBareMetal() async {
    final service = ref.read(bareMetalServiceProvider);
    // Pass vault path so credentials are stored in vault for portability
    await service.runClaudeLogin(vaultPath: _selectedVaultPath);
    setState(() => _currentStep = 4);
  }

  Future<void> _enableAutoStart() async {
    setState(() => _isLoading = true);

    try {
      final service = ref.read(bareMetalServiceProvider);
      await service.enableAutoStart();
      _currentStep = 5;
    } catch (e) {
      _error = 'Error enabling auto-start: $e';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _complete() async {
    // Set the server URL so the app switches to full mode (Chat + Vault tabs)
    // Both Lima VM and Bare Metal run on localhost:3333
    const serverUrl = 'http://localhost:3333';

    debugPrint('[ComputerSetupWizard] Setting server URL to $serverUrl');
    await ref.read(serverUrlProvider.notifier).setServerUrl(serverUrl);

    // Wait for the provider state to fully propagate
    // Poll until we confirm the URL is set (up to 2 seconds)
    String? savedUrl;
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      savedUrl = await ref.read(serverUrlProvider.future);
      if (savedUrl == serverUrl) {
        debugPrint('[ComputerSetupWizard] Server URL confirmed after ${(i + 1) * 100}ms');
        break;
      }
    }

    if (savedUrl != serverUrl) {
      debugPrint('[ComputerSetupWizard] WARNING: Server URL not confirmed, proceeding anyway. Got: $savedUrl');
    }

    // Invalidate the app mode provider to force a rebuild with new server URL
    ref.invalidate(appModeProvider);

    widget.onComplete?.call();
  }

  // ============================================================
  // Build Methods
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading && _selectedMode == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.rocket_launch,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Parachute Computer Setup',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.md),

        // Progress indicator (show after vault selection)
        if (_vaultPathSelected && _selectedMode != null) ...[
          _buildProgressIndicator(isDark),
          SizedBox(height: Spacing.lg),
        ],

        // Error message
        if (_error != null) ...[
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: BrandColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: BrandColors.error, size: 20),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: BrandColors.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),
        ],

        // Content
        if (!_vaultPathSelected)
          _buildVaultSelection(isDark)
        else if (_selectedMode == null)
          _buildModeSelection(isDark)
        else if (_selectedMode == ServerMode.limaVM)
          _buildLimaVMStep(isDark)
        else
          _buildBareMetalStep(isDark),
      ],
    );
  }

  Widget _buildProgressIndicator(bool isDark) {
    final steps = _selectedMode == ServerMode.limaVM
        ? ['Homebrew', 'Lima', 'VM', 'Claude', 'Ready']
        : ['Python', 'Server', 'CLI', 'Login', 'Auto-start', 'Ready'];

    return Row(
      children: List.generate(steps.length, (index) {
        final isCompleted = index < _currentStep;
        final isCurrent = index == _currentStep;

        return Expanded(
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isCompleted
                      ? BrandColors.success
                      : isCurrent
                          ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                          : Colors.grey.shade300,
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isCurrent ? Colors.white : Colors.grey.shade600,
                          ),
                        ),
                ),
              ),
              if (index < steps.length - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: isCompleted ? BrandColors.success : Colors.grey.shade300,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildVaultSelection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Where should Parachute store your data?',
          style: TextStyle(
            fontSize: TypographyTokens.bodyLarge,
            fontWeight: FontWeight.w500,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Your vault contains journals, chats, and files. Claude credentials will also be stored here, making your vault portable across machines.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Vault path options
        ..._vaultPathOptions.map((option) => Padding(
          padding: EdgeInsets.only(bottom: Spacing.md),
          child: _VaultOptionCard(
            isDark: isDark,
            label: option.label,
            path: option.path,
            description: option.description,
            isSelected: _selectedVaultPath == option.path,
            isRecommended: option.path.endsWith('/Parachute'),
            onTap: () => setState(() => _selectedVaultPath = option.path),
          ),
        )),

        // Custom path option
        _VaultOptionCard(
          isDark: isDark,
          label: 'Custom Location',
          path: _selectedVaultPath != null &&
                !_vaultPathOptions.any((o) => o.path == _selectedVaultPath)
              ? _selectedVaultPath!
              : 'Choose a folder...',
          description: 'Select a custom folder for your vault.',
          isSelected: _selectedVaultPath != null &&
              !_vaultPathOptions.any((o) => o.path == _selectedVaultPath),
          onTap: _selectCustomVaultPath,
        ),

        SizedBox(height: Spacing.lg),

        // Continue button
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FilledButton.icon(
              onPressed: _selectedVaultPath != null ? _confirmVaultPath : null,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _selectCustomVaultPath() async {
    // For now, show a dialog to enter a path manually
    // In the future, could use file_picker package
    final controller = TextEditingController(
      text: _selectedVaultPath ?? '$_homePath/Parachute',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom Vault Location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the full path to your vault folder:'),
            SizedBox(height: Spacing.md),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '/Users/you/Parachute',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            SizedBox(height: Spacing.sm),
            Text(
              'The folder will be created if it doesn\'t exist.',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Select'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() => _selectedVaultPath = result);
    }
  }

  Future<void> _confirmVaultPath() async {
    if (_selectedVaultPath == null) return;

    // Save the vault path
    await ref.read(vaultPathProvider.notifier).setVaultPath(_selectedVaultPath);

    // Create the directory if it doesn't exist
    final dir = Directory(_selectedVaultPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Create .claude directory for credentials
    final claudeDir = Directory('$_selectedVaultPath/.claude');
    if (!await claudeDir.exists()) {
      await claudeDir.create(recursive: true);
    }

    setState(() => _vaultPathSelected = true);
  }

  Widget _buildModeSelection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'How would you like to run Parachute?',
          style: TextStyle(
            fontSize: TypographyTokens.bodyLarge,
            fontWeight: FontWeight.w500,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Lima VM Option
        _ModeCard(
          isDark: isDark,
          icon: Icons.security,
          title: 'Isolated VM',
          subtitle: 'Recommended for shared computers',
          description: 'Runs in a Linux virtual machine. Claude can only access your vault, nothing else on your computer.',
          features: const [
            'Complete filesystem isolation',
            'Requires ~8GB RAM, ~30GB disk',
            'Slightly slower startup',
          ],
          isSelected: _selectedMode == ServerMode.limaVM,
          onTap: () => _selectMode(ServerMode.limaVM),
        ),

        SizedBox(height: Spacing.md),

        // Bare Metal Option
        _ModeCard(
          isDark: isDark,
          icon: Icons.speed,
          title: 'Direct Installation',
          subtitle: 'Recommended for dedicated machines',
          description: 'Runs directly on macOS. Best performance, access to native features like MLX.',
          features: const [
            'Full native performance',
            'Access to MLX, Metal, native builds',
            'Best for dedicated Parachute machines',
          ],
          isSelected: _selectedMode == ServerMode.bareMetal,
          onTap: () => _selectMode(ServerMode.bareMetal),
        ),

        SizedBox(height: Spacing.lg),

        // Back button
        TextButton.icon(
          onPressed: () => setState(() => _vaultPathSelected = false),
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Change vault location'),
        ),
      ],
    );
  }

  // Lima VM step builders
  Widget _buildLimaVMStep(bool isDark) {
    switch (_currentStep) {
      case 0:
        return _buildHomebrewStep(isDark);
      case 1:
        return _buildLimaStep(isDark);
      case 2:
        return _buildVMStep(isDark);
      case 3:
        return _buildClaudeStepLima(isDark);
      case 4:
        return _buildCompleteStepLima(isDark);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildHomebrewStep(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.local_drink,
      title: 'Install Homebrew',
      description: 'Homebrew is a package manager for macOS. We\'ll use it to install the tools needed for Parachute Computer.',
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _installHomebrew,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Install Homebrew'),
      ),
      checkAction: OutlinedButton(
        onPressed: _checkPrerequisites,
        child: const Text('Check Again'),
      ),
      backAction: TextButton(
        onPressed: () => setState(() => _selectedMode = null),
        child: const Text('← Back'),
      ),
    );
  }

  Widget _buildLimaStep(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.computer,
      title: 'Install Lima',
      description: 'Lima runs Linux virtual machines on macOS. This provides complete isolation for Claude.',
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _installLima,
        icon: _isLoading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.download, size: 18),
        label: Text(_isLoading ? 'Installing...' : 'Install Lima'),
      ),
    );
  }

  Widget _buildVMStep(bool isDark) {
    final vmStatus = ref.watch(limaVMStatusProvider);

    return vmStatus.when(
      data: (status) {
        if (status == LimaVMStatus.running) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _currentStep == 2) {
              setState(() => _currentStep = 3);
            }
          });
        }

        final description = _isLoading && _vmProgressMessage != null
            ? _vmProgressMessage!
            : 'This will download Ubuntu and set up an isolated environment. First-time setup typically takes 3-5 minutes.';

        return _StepCard(
          isDark: isDark,
          icon: Icons.dns,
          title: 'Create Parachute VM',
          description: description,
          action: FilledButton.icon(
            onPressed: _isLoading ? null : _createAndStartVM,
            icon: _isLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(_isLoading ? 'Creating...' : 'Create & Start VM'),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
    );
  }

  Widget _buildClaudeStepLima(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.key,
      title: 'Authenticate with Claude',
      description: 'This opens Terminal with an auth URL. Copy the URL to your browser to sign in with your Anthropic account.',
      action: FilledButton.icon(
        onPressed: _authenticateClaudeLima,
        icon: const Icon(Icons.login, size: 18),
        label: const Text('Run claude login'),
      ),
      skipAction: TextButton(
        onPressed: () => setState(() => _currentStep = 4),
        child: const Text('Skip for now'),
      ),
    );
  }

  Widget _buildCompleteStepLima(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.check_circle,
      iconColor: BrandColors.success,
      title: 'Setup Complete!',
      description: 'Parachute Computer is ready. Claude runs in an isolated VM and can only access your vault.',
      action: FilledButton.icon(
        onPressed: _complete,
        icon: const Icon(Icons.arrow_forward, size: 18),
        label: const Text('Get Started'),
      ),
    );
  }

  // Bare Metal step builders
  Widget _buildBareMetalStep(bool isDark) {
    switch (_currentStep) {
      case 0:
        return _buildPythonStep(isDark);
      case 1:
        return _buildServerSetupStep(isDark);
      case 2:
        return _buildClaudeCLIStep(isDark);
      case 3:
        return _buildClaudeStepBareMetal(isDark);
      case 4:
        return _buildAutoStartStep(isDark);
      case 5:
        return _buildCompleteStepBareMetal(isDark);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPythonStep(bool isDark) {
    String description;
    if (_pythonVersion != null) {
      // Parse version to give specific advice
      final match = RegExp(r'Python (\d+)\.(\d+)').firstMatch(_pythonVersion!);
      if (match != null) {
        final minor = int.tryParse(match.group(2)!) ?? 0;
        if (minor > 13) {
          description = 'Found: $_pythonVersion (too new - need 3.10-3.13)';
        } else if (minor < 10) {
          description = 'Found: $_pythonVersion (too old - need 3.10-3.13)';
        } else {
          description = 'Found: $_pythonVersion';
        }
      } else {
        description = 'Found: $_pythonVersion (need 3.10-3.13)';
      }
    } else {
      description = 'Python 3.10-3.13 is required. (3.14+ is too new and doesn\'t have all packages yet.)';
    }

    return _StepCard(
      isDark: isDark,
      icon: Icons.code,
      title: 'Install Python',
      description: description,
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _installPython,
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Install Python'),
      ),
      checkAction: OutlinedButton(
        onPressed: _checkPrerequisites,
        child: const Text('Check Again'),
      ),
      backAction: TextButton(
        onPressed: () => setState(() => _selectedMode = null),
        child: const Text('← Back'),
      ),
    );
  }

  Widget _buildServerSetupStep(bool isDark) {
    final description = _isLoading && _setupProgressMessage != null
        ? _setupProgressMessage!
        : 'This will install the Parachute server and its dependencies.';

    return _StepCard(
      isDark: isDark,
      icon: Icons.dns,
      title: 'Set Up Server',
      description: description,
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _setupBareMetalServer,
        icon: _isLoading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.play_arrow, size: 18),
        label: Text(_isLoading ? 'Setting up...' : 'Set Up Server'),
      ),
    );
  }

  Widget _buildClaudeCLIStep(bool isDark) {
    if (_claudeInstalled) {
      // Claude CLI already installed, auto-advance
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == 2) {
          setState(() => _currentStep = 3);
        }
      });
      return const SizedBox.shrink();
    }

    // Show installation instructions
    String description;
    Widget action;

    if (_nodeInstalled) {
      description = 'Claude CLI is required but not installed. Click below to install it via npm and authenticate.';
      action = FilledButton.icon(
        onPressed: _isLoading ? null : _installClaudeCLI,
        icon: _isLoading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.download, size: 18),
        label: const Text('Install Claude CLI'),
      );
    } else {
      description = 'Claude CLI requires Node.js. Install Node.js first, then install Claude CLI.';
      action = FilledButton.icon(
        onPressed: _isLoading ? null : _installNode,
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Install Node.js'),
      );
    }

    return _StepCard(
      isDark: isDark,
      icon: Icons.terminal,
      title: 'Install Claude CLI',
      description: description,
      action: action,
      checkAction: OutlinedButton(
        onPressed: _checkPrerequisites,
        child: const Text('Check Again'),
      ),
    );
  }

  Future<void> _installNode() async {
    // Open Node.js download page
    final url = Uri.parse('https://nodejs.org/');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Install Node.js'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Install Node.js via Homebrew:'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: SelectableText(
                        'brew install node',
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(const ClipboardData(text: 'brew install node'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text('Or download from nodejs.org'),
              const SizedBox(height: 12),
              const Text('After installation, click "Check Again" below.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _checkPrerequisites();
              },
              child: const Text('Check Again'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _installClaudeCLI() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final service = ref.read(bareMetalServiceProvider);
      // Pass vault path so credentials are stored in vault for portability
      await service.installClaudeCLI(vaultPath: _selectedVaultPath);

      // The Terminal will handle installation - show a dialog explaining next steps
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Installing Claude CLI'),
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('A Terminal window has opened to install Claude CLI.'),
                SizedBox(height: 12),
                Text('After installation completes:'),
                SizedBox(height: 8),
                Text('1. The Terminal will prompt you to authenticate'),
                Text('2. Follow the login instructions in the Terminal'),
                Text('3. Return here and click "Check Again"'),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _checkPrerequisites();
                },
                child: const Text('Check Again'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      _error = 'Error installing Claude CLI: $e';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildClaudeStepBareMetal(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.key,
      title: 'Authenticate with Claude',
      description: 'This opens Terminal to authenticate. Sign in with your Anthropic account.',
      action: FilledButton.icon(
        onPressed: _authenticateClaudeBareMetal,
        icon: const Icon(Icons.login, size: 18),
        label: const Text('Run claude login'),
      ),
      skipAction: TextButton(
        onPressed: () => setState(() => _currentStep = 4),
        child: const Text('Skip for now'),
      ),
    );
  }

  Widget _buildAutoStartStep(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.autorenew,
      title: 'Enable Auto-Start',
      description: 'Start the Parachute server automatically when you log in. Recommended for dedicated machines.',
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _enableAutoStart,
        icon: _isLoading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check, size: 18),
        label: const Text('Enable Auto-Start'),
      ),
      skipAction: TextButton(
        onPressed: () => setState(() => _currentStep = 5),
        child: const Text('Skip'),
      ),
    );
  }

  Widget _buildCompleteStepBareMetal(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.check_circle,
      iconColor: BrandColors.success,
      title: 'Setup Complete!',
      description: 'Parachute Computer is ready. The server runs directly on your Mac for best performance.',
      action: FilledButton.icon(
        onPressed: _complete,
        icon: const Icon(Icons.arrow_forward, size: 18),
        label: const Text('Get Started'),
      ),
    );
  }
}

// ============================================================
// Helper Widgets
// ============================================================

class _ModeCard extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final String title;
  final String subtitle;
  final String description;
  final List<String> features;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.isDark,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.features,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
        : Colors.grey.shade300;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise).withValues(alpha: 0.1)
              : (isDark ? BrandColors.nightSurfaceElevated : Colors.white),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 28,
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                ),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: TypographyTokens.bodyLarge,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle, color: BrandColors.success, size: 24),
              ],
            ),
            SizedBox(height: Spacing.md),
            Text(
              description,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            ...features.map((f) => Padding(
              padding: EdgeInsets.only(top: Spacing.xs),
              child: Row(
                children: [
                  Icon(Icons.check, size: 16, color: BrandColors.success),
                  SizedBox(width: Spacing.xs),
                  Text(
                    f,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            )),
          ],
        ),
      ),
    );
  }
}

class _VaultOptionCard extends StatelessWidget {
  final bool isDark;
  final String label;
  final String path;
  final String description;
  final bool isSelected;
  final bool isRecommended;
  final VoidCallback onTap;

  const _VaultOptionCard({
    required this.isDark,
    required this.label,
    required this.path,
    required this.description,
    required this.isSelected,
    this.isRecommended = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
        : Colors.grey.shade300;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise).withValues(alpha: 0.1)
              : (isDark ? BrandColors.nightSurfaceElevated : Colors.white),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(
              Icons.folder,
              size: 24,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: TypographyTokens.bodyMedium,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                      if (isRecommended) ...[
                        SizedBox(width: Spacing.xs),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
                          decoration: BoxDecoration(
                            color: BrandColors.success.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Recommended',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: BrandColors.success,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: 2),
                  Text(
                    path,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontFamily: 'monospace',
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: BrandColors.success, size: 24),
          ],
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final bool isDark;
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String description;
  final Widget action;
  final Widget? checkAction;
  final Widget? skipAction;
  final Widget? backAction;

  const _StepCard({
    required this.isDark,
    required this.icon,
    this.iconColor,
    required this.title,
    required this.description,
    required this.action,
    this.checkAction,
    this.skipAction,
    this.backAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 24,
                color: iconColor ?? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise),
              ),
              SizedBox(width: Spacing.sm),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            description,
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),
          Row(
            children: [
              if (backAction != null) ...[
                backAction!,
                SizedBox(width: Spacing.sm),
              ],
              action,
              if (checkAction != null) ...[
                SizedBox(width: Spacing.sm),
                checkAction!,
              ],
              if (skipAction != null) ...[
                const Spacer(),
                skipAction!,
              ],
            ],
          ),
        ],
      ),
    );
  }
}
