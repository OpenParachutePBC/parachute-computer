import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/vault_entry.dart';
import '../providers/chat_providers.dart';

/// A dialog for picking a working directory from the vault
class DirectoryPickerDialog extends ConsumerStatefulWidget {
  final String? initialPath;

  const DirectoryPickerDialog({super.key, this.initialPath});

  @override
  ConsumerState<DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends ConsumerState<DirectoryPickerDialog> {
  late String _currentPath;
  final List<String> _pathHistory = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? '';
  }

  void _navigateTo(String path) {
    setState(() {
      _pathHistory.add(_currentPath);
      _currentPath = path;
    });
  }

  void _navigateBack() {
    if (_pathHistory.isNotEmpty) {
      setState(() {
        _currentPath = _pathHistory.removeLast();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(vaultDirectoryProvider(_currentPath));

    return Dialog(
      child: Container(
        width: 400,
        height: 500,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _pathHistory.isNotEmpty ? _navigateBack : null,
                ),
                Expanded(
                  child: Text(
                    _currentPath.isEmpty ? 'Vault Root' : _currentPath,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),

            // Current directory selection
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(_currentPath.isEmpty ? 'Use vault root' : 'Use this directory'),
              subtitle: _currentPath.isNotEmpty
                  ? Text(_currentPath, style: Theme.of(context).textTheme.bodySmall)
                  : null,
              onTap: () => Navigator.of(context).pop(_currentPath.isEmpty ? null : _currentPath),
            ),
            const Divider(),

            // Directory list
            Expanded(
              child: entriesAsync.when(
                data: (entries) {
                  final directories = entries.where((e) => e.isDirectory).toList();
                  if (directories.isEmpty) {
                    return const Center(
                      child: Text('No subdirectories'),
                    );
                  }
                  return ListView.builder(
                    itemCount: directories.length,
                    itemBuilder: (context, index) {
                      final entry = directories[index];
                      return _DirectoryTile(
                        entry: entry,
                        onTap: () => _navigateTo(entry.relativePath),
                        onSelect: () => Navigator.of(context).pop(entry.relativePath),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48),
                      const SizedBox(height: 8),
                      Text('Error: $e'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectoryTile extends StatelessWidget {
  final VaultEntry entry;
  final VoidCallback onTap;
  final VoidCallback onSelect;

  const _DirectoryTile({
    required this.entry,
    required this.onTap,
    required this.onSelect,
  });

  String? get _contextFileLabel {
    if (entry.hasClaudeMd) {
      return 'Has CLAUDE.md';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        entry.hasContextFile
            ? Icons.folder_special
            : entry.isGitRepo
                ? Icons.source
                : Icons.folder,
        color: entry.hasContextFile ? Colors.amber : null,
      ),
      title: Text(entry.name),
      subtitle: _contextFileLabel != null
          ? Text(_contextFileLabel!, style: const TextStyle(fontSize: 12))
          : entry.isGitRepo
              ? const Text('Git repository', style: TextStyle(fontSize: 12))
              : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Select this directory',
            onPressed: onSelect,
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Shows a directory picker dialog and returns the selected path
///
/// Returns null if canceled, empty string for vault root, or a relative path
Future<String?> showDirectoryPicker(BuildContext context, {String? initialPath}) {
  return showDialog<String?>(
    context: context,
    builder: (context) => DirectoryPickerDialog(initialPath: initialPath),
  );
}
