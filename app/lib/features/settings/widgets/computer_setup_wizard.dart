import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/lima_vm_provider.dart';
import 'package:parachute/core/services/lima_vm_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Setup wizard for Parachute Computer
///
/// Guides users through:
/// 1. Installing Homebrew (if needed)
/// 2. Installing Lima (if needed)
/// 3. Creating and starting the VM
/// 4. Authenticating with Claude
class ComputerSetupWizard extends ConsumerStatefulWidget {
  final VoidCallback? onComplete;

  const ComputerSetupWizard({super.key, this.onComplete});

  @override
  ConsumerState<ComputerSetupWizard> createState() => _ComputerSetupWizardState();
}

class _ComputerSetupWizardState extends ConsumerState<ComputerSetupWizard> {
  int _currentStep = 0;
  bool _isLoading = false;
  String? _error;
  bool _homebrewInstalled = false;
  bool _limaInstalled = false;
  String? _vmProgressMessage;
  Stopwatch? _vmCreationTimer;

  @override
  void initState() {
    super.initState();
    _checkPrerequisites();
  }

  /// Known paths where brew might be installed (GUI apps don't inherit shell PATH)
  static const List<String> _brewPaths = [
    '/opt/homebrew/bin/brew', // Apple Silicon
    '/usr/local/bin/brew', // Intel
  ];

  Future<void> _checkPrerequisites() async {
    setState(() => _isLoading = true);

    try {
      // Check Homebrew by looking for it in known paths
      // (GUI apps don't inherit shell PATH, so 'which' doesn't work)
      _homebrewInstalled = _brewPaths.any((p) => File(p).existsSync());

      // Check Lima using the service's detection
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
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _installHomebrew() async {
    // Open Homebrew website - user installs manually
    final url = Uri.parse('https://brew.sh');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }

    // Show instructions
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
                    Expanded(
                      child: SelectableText(
                        '/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
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

  /// Get the path to brew, or null if not found
  String? get _brewPath {
    for (final p in _brewPaths) {
      if (File(p).existsSync()) return p;
    }
    return null;
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

      // Run brew install lima using full path
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
      _vmCreationTimer = Stopwatch()..start();
    });

    try {
      // Use initialized provider to get vault path for developer mode detection
      final service = await ref.read(limaVMServiceInitializedProvider.future);

      // First, ensure base server is installed
      // For developers: skips if ~/Vault/projects/parachute/base exists
      // For users: installs to ~/Library/Application Support/Parachute/base
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

      // Now create/start the VM
      if (mounted) {
        setState(() => _vmProgressMessage = 'Downloading Ubuntu & creating VM...');
      }
      final success = await service.start();

      if (success) {
        if (mounted) {
          setState(() => _vmProgressMessage = 'Starting server...');
        }
        // Start the server too
        await service.startServer();
        _currentStep = 3;
      } else {
        _error = service.lastError ?? 'Failed to create VM';
      }
    } catch (e) {
      _error = 'Error creating VM: $e';
    } finally {
      _vmCreationTimer?.stop();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _vmProgressMessage = null;
        });
      }
    }
  }

  Future<void> _authenticateClaude() async {
    final service = ref.read(limaVMServiceProvider);
    await service.runClaudeLogin();

    // Move to complete
    setState(() => _currentStep = 4);
  }

  void _complete() {
    widget.onComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading && _currentStep == 0) {
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

        // Progress indicator
        _buildProgressIndicator(isDark),
        SizedBox(height: Spacing.lg),

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

        // Current step content
        _buildStepContent(isDark),
      ],
    );
  }

  Widget _buildProgressIndicator(bool isDark) {
    final steps = ['Homebrew', 'Lima', 'VM', 'Claude', 'Ready'];

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

  Widget _buildStepContent(bool isDark) {
    switch (_currentStep) {
      case 0:
        return _buildHomebrewStep(isDark);
      case 1:
        return _buildLimaStep(isDark);
      case 2:
        return _buildVMStep(isDark);
      case 3:
        return _buildClaudeStep(isDark);
      case 4:
        return _buildCompleteStep(isDark);
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
    );
  }

  Widget _buildLimaStep(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.computer,
      title: 'Install Lima',
      description: 'Lima runs Linux virtual machines on macOS. This provides complete isolation for Claude - it can only access your vault.',
      action: FilledButton.icon(
        onPressed: _isLoading ? null : _installLima,
        icon: _isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
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
          // Already running, skip to next step
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
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(_isLoading ? 'Creating...' : 'Create & Start VM'),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text('Error: $e'),
    );
  }

  Widget _buildClaudeStep(bool isDark) {
    return _StepCard(
      isDark: isDark,
      icon: Icons.key,
      title: 'Authenticate with Claude',
      description: 'This opens Terminal with an auth URL. Copy the URL to your browser to sign in with your Anthropic account.',
      action: FilledButton.icon(
        onPressed: _authenticateClaude,
        icon: const Icon(Icons.login, size: 18),
        label: const Text('Run claude login'),
      ),
      skipAction: TextButton(
        onPressed: () => setState(() => _currentStep = 4),
        child: const Text('Skip for now'),
      ),
    );
  }

  Widget _buildCompleteStep(bool isDark) {
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

  const _StepCard({
    required this.isDark,
    required this.icon,
    this.iconColor,
    required this.title,
    required this.description,
    required this.action,
    this.checkAction,
    this.skipAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
            .withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
              .withValues(alpha: 0.3),
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
