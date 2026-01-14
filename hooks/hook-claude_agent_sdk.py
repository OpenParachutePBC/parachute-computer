"""
PyInstaller hook for claude_agent_sdk.

The Claude Agent SDK includes a bundled Claude CLI binary that must be
included in the distribution. This hook ensures it's properly collected.
"""

import os
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, get_package_paths

# Get the package path
_, pkg_path = get_package_paths('claude_agent_sdk')
pkg_path = Path(pkg_path)

# Collect the bundled CLI
datas = []
binaries = []

bundled_dir = pkg_path / '_bundled'
if bundled_dir.exists():
    claude_binary = bundled_dir / 'claude'
    if claude_binary.exists():
        # Add as a binary (executable)
        binaries.append((str(claude_binary), 'claude_agent_sdk/_bundled'))
        print(f"[hook-claude_agent_sdk] Found bundled CLI: {claude_binary}")
    else:
        print(f"[hook-claude_agent_sdk] Warning: claude binary not found in {bundled_dir}")
else:
    print(f"[hook-claude_agent_sdk] Warning: _bundled directory not found")

# Also collect any other data files
datas += collect_data_files('claude_agent_sdk')

# Hidden imports for internal modules
hiddenimports = [
    'claude_agent_sdk._internal',
    'claude_agent_sdk._internal.parser',
    'claude_agent_sdk._errors',
    'claude_agent_sdk.client',
    'claude_agent_sdk.query',
    'claude_agent_sdk.types',
]
