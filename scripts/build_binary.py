#!/usr/bin/env python3
"""
Build script for creating Parachute Server standalone binary.

This script:
1. Ensures PyInstaller is installed
2. Builds the binary using the spec file
3. Creates a distribution package

Usage:
    python scripts/build_binary.py [--clean] [--onefile]

Options:
    --clean     Remove previous build artifacts before building
    --onefile   Build as a single executable (larger, slower startup)
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Build Parachute Server binary")
    parser.add_argument(
        "--clean", action="store_true", help="Remove previous build artifacts"
    )
    parser.add_argument(
        "--onefile",
        action="store_true",
        help="Build as single executable (not recommended)",
    )
    parser.add_argument(
        "--debug", action="store_true", help="Build with debug output"
    )
    args = parser.parse_args()

    # Get paths
    base_dir = Path(__file__).parent.parent
    spec_file = base_dir / "parachute_server.spec"
    build_dir = base_dir / "build"
    dist_dir = base_dir / "dist"
    venv_python = base_dir / "venv" / "bin" / "python"

    # Use venv python if available
    python = str(venv_python) if venv_python.exists() else sys.executable

    print("=" * 60)
    print("Parachute Server Binary Builder")
    print("=" * 60)
    print(f"Base directory: {base_dir}")
    print(f"Python: {python}")
    print()

    # Clean if requested
    if args.clean:
        print("Cleaning previous builds...")
        if build_dir.exists():
            shutil.rmtree(build_dir)
            print(f"  Removed {build_dir}")
        if dist_dir.exists():
            shutil.rmtree(dist_dir)
            print(f"  Removed {dist_dir}")
        print()

    # Ensure PyInstaller is installed
    print("Checking PyInstaller installation...")
    try:
        result = subprocess.run(
            [python, "-c", "import PyInstaller; print(PyInstaller.__version__)"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print(f"  PyInstaller version: {result.stdout.strip()}")
        else:
            print("  PyInstaller not found, installing...")
            subprocess.run(
                [python, "-m", "pip", "install", "pyinstaller"], check=True
            )
    except Exception as e:
        print(f"  Error checking PyInstaller: {e}")
        print("  Installing PyInstaller...")
        subprocess.run([python, "-m", "pip", "install", "pyinstaller"], check=True)
    print()

    # Build command
    cmd = [
        python,
        "-m",
        "PyInstaller",
        str(spec_file),
        "--distpath",
        str(dist_dir),
        "--workpath",
        str(build_dir),
    ]

    if args.debug:
        cmd.append("--log-level=DEBUG")

    if args.onefile:
        # Note: onefile mode requires a different spec file structure
        print("Warning: --onefile mode not fully supported with current spec")
        print("         Building in directory mode instead")
        print()

    print("Building binary...")
    print(f"  Command: {' '.join(cmd)}")
    print()

    try:
        result = subprocess.run(cmd, cwd=base_dir)
        if result.returncode != 0:
            print(f"\nBuild failed with return code {result.returncode}")
            sys.exit(result.returncode)
    except Exception as e:
        print(f"\nBuild error: {e}")
        sys.exit(1)

    # Check output
    output_dir = dist_dir / "parachute-server"
    server_binary = output_dir / "parachute-server"
    mcp_binary = output_dir / "parachute-mcp"

    print()
    print("=" * 60)
    print("Build Results")
    print("=" * 60)

    if output_dir.exists():
        print(f"Output directory: {output_dir}")

        if server_binary.exists():
            size_mb = server_binary.stat().st_size / (1024 * 1024)
            print(f"  parachute-server: {size_mb:.1f} MB")
        else:
            print("  Warning: parachute-server not found")

        if mcp_binary.exists():
            size_mb = mcp_binary.stat().st_size / (1024 * 1024)
            print(f"  parachute-mcp: {size_mb:.1f} MB")
        else:
            print("  Warning: parachute-mcp not found")

        # Calculate total size
        total_size = sum(f.stat().st_size for f in output_dir.rglob("*") if f.is_file())
        print(f"  Total: {total_size / (1024 * 1024):.1f} MB")

        print()
        print("To test the binary:")
        print(f"  {server_binary}")
        print()
        print("Or with custom vault path:")
        print(f"  VAULT_PATH=~/Parachute {server_binary}")

    else:
        print(f"Error: Output directory not found: {output_dir}")
        sys.exit(1)


if __name__ == "__main__":
    main()
