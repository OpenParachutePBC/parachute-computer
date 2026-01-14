# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec file for Parachute Base Server.

This creates a standalone executable that includes:
- FastAPI server with uvicorn
- Claude Agent SDK (with bundled Claude CLI)
- All Python dependencies
- MCP server as a separate entry point

Usage:
    pyinstaller parachute_server.spec

Output:
    dist/parachute-server (macOS/Linux)
    dist/parachute-server.exe (Windows)
"""

import os
import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules

block_cipher = None

# Get the base directory
BASE_DIR = Path(SPECPATH)
HOOKS_DIR = BASE_DIR / 'hooks'

# Collect all data files and hidden imports for key packages
datas = []
hiddenimports = []
binaries = []

# ============================================================================
# Claude Agent SDK - Critical: includes bundled Claude CLI
# ============================================================================
try:
    claude_sdk_datas, claude_sdk_binaries, claude_sdk_hiddenimports = collect_all('claude_agent_sdk')
    datas += claude_sdk_datas
    binaries += claude_sdk_binaries
    hiddenimports += claude_sdk_hiddenimports
except Exception as e:
    print(f"Warning: Could not collect claude_agent_sdk: {e}")

# ============================================================================
# FastAPI and dependencies
# ============================================================================
hiddenimports += [
    # FastAPI
    'fastapi',
    'fastapi.staticfiles',
    'fastapi.responses',
    'fastapi.middleware.cors',

    # Starlette (FastAPI dependency)
    'starlette',
    'starlette.applications',
    'starlette.routing',
    'starlette.middleware',
    'starlette.responses',
    'starlette.requests',
    'starlette.staticfiles',
    'starlette.websockets',

    # Uvicorn
    'uvicorn',
    'uvicorn.config',
    'uvicorn.main',
    'uvicorn.logging',
    'uvicorn.loops',
    'uvicorn.loops.auto',
    'uvicorn.protocols',
    'uvicorn.protocols.http',
    'uvicorn.protocols.http.auto',
    'uvicorn.protocols.websockets',
    'uvicorn.protocols.websockets.auto',
    'uvicorn.lifespan',
    'uvicorn.lifespan.on',

    # Pydantic
    'pydantic',
    'pydantic.main',
    'pydantic_settings',
    'pydantic_core',

    # SSE for streaming
    'sse_starlette',
    'sse_starlette.sse',

    # Database
    'aiosqlite',
    'sqlite3',

    # HTTP client
    'httpx',
    'httpx._transports',
    'httpx._transports.default',

    # YAML
    'yaml',

    # Frontmatter
    'frontmatter',

    # Watchfiles
    'watchfiles',

    # MCP server (for spawning)
    'mcp',
    'mcp.server',
    'mcp.server.stdio',
    'mcp.types',

    # Async files
    'aiofiles',

    # Multipart
    'multipart',
    'python_multipart',

    # Email validation (pydantic uses it)
    'email_validator',

    # AnyIO (async foundation)
    'anyio',
    'anyio._backends',
    'anyio._backends._asyncio',

    # Parachute modules
    'parachute',
    'parachute.api',
    'parachute.api.auth',
    'parachute.api.health',
    'parachute.api.sessions',
    'parachute.api.context_folders',
    'parachute.api.prompts',
    'parachute.api.mcp',
    'parachute.api.imports',
    'parachute.api.skills',
    'parachute.api.claude_code',
    'parachute.core',
    'parachute.core.orchestrator',
    'parachute.core.session_manager',
    'parachute.core.claude_sdk',
    'parachute.core.curator_service',
    'parachute.core.scheduler',
    'parachute.core.import_service',
    'parachute.core.import_curator',
    'parachute.db',
    'parachute.db.database',
    'parachute.lib',
    'parachute.lib.auth',
    'parachute.lib.server_config',
    'parachute.lib.agent_loader',
    'parachute.lib.context_loader',
    'parachute.lib.mcp_loader',
    'parachute.lib.vault_utils',
    'parachute.lib.permissions',
    'parachute.lib.para_id',
    'parachute.lib.logger',
    'parachute.models',
    'parachute.models.session',
    'parachute.models.agent',
    'parachute.models.requests',
    'parachute.config',
    'parachute.server',
    'parachute.mcp_server',
]

# Collect pydantic extras
try:
    pydantic_datas, pydantic_binaries, pydantic_hiddenimports = collect_all('pydantic')
    datas += pydantic_datas
    binaries += pydantic_binaries
    hiddenimports += pydantic_hiddenimports
except Exception as e:
    print(f"Warning: Could not collect pydantic: {e}")

# Collect uvicorn extras
try:
    uvicorn_datas, uvicorn_binaries, uvicorn_hiddenimports = collect_all('uvicorn')
    datas += uvicorn_datas
    binaries += uvicorn_binaries
    hiddenimports += uvicorn_hiddenimports
except Exception as e:
    print(f"Warning: Could not collect uvicorn: {e}")

# Collect MCP package
try:
    mcp_datas, mcp_binaries, mcp_hiddenimports = collect_all('mcp')
    datas += mcp_datas
    binaries += mcp_binaries
    hiddenimports += mcp_hiddenimports
except Exception as e:
    print(f"Warning: Could not collect mcp: {e}")

# ============================================================================
# Main Server Analysis
# ============================================================================
server_analysis = Analysis(
    [str(BASE_DIR / 'parachute' / 'server.py')],
    pathex=[str(BASE_DIR)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[str(HOOKS_DIR)],
    hooksconfig={},
    runtime_hooks=[str(HOOKS_DIR / 'rthook_claude_sdk.py')],
    excludes=[
        # Exclude dev/test packages
        'pytest',
        'pytest_asyncio',
        'pytest_cov',
        'ruff',
        'mypy',
        'black',
        'isort',
        # Exclude heavy unused packages
        'matplotlib',
        'numpy',
        'pandas',
        'scipy',
        'PIL',
        'cv2',
        'tensorflow',
        'torch',
        'tkinter',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

# ============================================================================
# MCP Server Analysis (separate executable for spawning)
# ============================================================================
mcp_analysis = Analysis(
    [str(BASE_DIR / 'parachute' / 'mcp_server.py')],
    pathex=[str(BASE_DIR)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports + [
        'parachute.db.database',
        'parachute.core.session_manager',
    ],
    hookspath=[str(HOOKS_DIR)],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'pytest', 'pytest_asyncio', 'pytest_cov', 'ruff', 'mypy',
        'matplotlib', 'numpy', 'pandas', 'scipy', 'PIL', 'cv2',
        'tensorflow', 'torch', 'tkinter',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

# ============================================================================
# Merge analyses to share common files
# ============================================================================
MERGE(
    (server_analysis, 'parachute-server', 'parachute-server'),
    (mcp_analysis, 'parachute-mcp', 'parachute-mcp'),
)

# ============================================================================
# Create PYZ archives
# ============================================================================
server_pyz = PYZ(server_analysis.pure, server_analysis.zipped_data, cipher=block_cipher)
mcp_pyz = PYZ(mcp_analysis.pure, mcp_analysis.zipped_data, cipher=block_cipher)

# ============================================================================
# Create executables
# ============================================================================
server_exe = EXE(
    server_pyz,
    server_analysis.scripts,
    [],
    exclude_binaries=True,
    name='parachute-server',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

mcp_exe = EXE(
    mcp_pyz,
    mcp_analysis.scripts,
    [],
    exclude_binaries=True,
    name='parachute-mcp',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# ============================================================================
# Collect into distribution folder
# ============================================================================
coll = COLLECT(
    server_exe,
    server_analysis.binaries,
    server_analysis.zipfiles,
    server_analysis.datas,
    mcp_exe,
    mcp_analysis.binaries,
    mcp_analysis.zipfiles,
    mcp_analysis.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='parachute-server',
)
