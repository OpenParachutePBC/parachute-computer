"""
Runtime hook for claude_agent_sdk.

This hook runs at application startup to ensure the bundled Claude CLI
can be found by the SDK when running from a PyInstaller bundle.
"""

import os
import sys


def _setup_bundled_cli():
    """Configure the environment for the bundled Claude CLI."""
    # When running as a PyInstaller bundle, sys._MEIPASS points to the
    # temporary directory where files are extracted
    if hasattr(sys, '_MEIPASS'):
        bundle_dir = sys._MEIPASS

        # The claude binary should be in claude_agent_sdk/_bundled/
        bundled_cli = os.path.join(bundle_dir, 'claude_agent_sdk', '_bundled', 'claude')

        if os.path.exists(bundled_cli):
            # Make it executable
            try:
                os.chmod(bundled_cli, 0o755)
            except Exception:
                pass

            # Add to PATH so the SDK can find it
            bin_dir = os.path.dirname(bundled_cli)
            current_path = os.environ.get('PATH', '')
            if bin_dir not in current_path:
                os.environ['PATH'] = bin_dir + os.pathsep + current_path

            # Also set CLAUDE_CLI_PATH environment variable
            os.environ['CLAUDE_CLI_PATH'] = bundled_cli


_setup_bundled_cli()
