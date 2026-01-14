#
# Build script for Parachute Computer (Windows)
#
# This script:
# 1. Builds the Python server binary using PyInstaller
# 2. Builds the Flutter Windows app
# 3. Bundles them together into a zip file
#
# Usage:
#   cd app
#   .\scripts\build_windows_bundle.ps1 [-SkipServer] [-SkipFlutter] [-Clean]
#
# Environment:
#   PARACHUTE_BASE_DIR - Path to base server (default: ..\base)
#
# Output:
#   app\dist\parachute-windows-x64.zip
#

param(
    [switch]$SkipServer,
    [switch]$SkipFlutter,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Split-Path -Parent $ScriptDir
$BaseDir = if ($env:PARACHUTE_BASE_DIR) { $env:PARACHUTE_BASE_DIR } else { Join-Path (Split-Path -Parent $AppDir) "base" }
$DistDir = Join-Path $AppDir "dist"

Write-Host "============================================" -ForegroundColor Blue
Write-Host "  Parachute Computer - Windows Build" -ForegroundColor Blue
Write-Host "============================================" -ForegroundColor Blue
Write-Host ""

# Show paths
Write-Host "  App dir:    $AppDir"
Write-Host "  Base dir:   $BaseDir"
Write-Host "  Output:     $DistDir"
Write-Host ""

# Clean if requested
if ($Clean) {
    Write-Host "Cleaning previous builds..." -ForegroundColor Yellow
    if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
    if (Test-Path (Join-Path $BaseDir "build")) { Remove-Item -Recurse -Force (Join-Path $BaseDir "build") }
    if (Test-Path (Join-Path $BaseDir "dist")) { Remove-Item -Recurse -Force (Join-Path $BaseDir "dist") }
    if (Test-Path (Join-Path $AppDir "build")) { Remove-Item -Recurse -Force (Join-Path $AppDir "build") }
    Write-Host "Clean complete" -ForegroundColor Green
    Write-Host ""
}

# Create dist directory
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

# Step 1: Build Python server
if (-not $SkipServer) {
    Write-Host "Step 1: Building Python server..." -ForegroundColor Blue
    Push-Location $BaseDir

    # Check for venv
    $VenvActivate = Join-Path $BaseDir "venv\Scripts\Activate.ps1"
    if (-not (Test-Path $VenvActivate)) {
        Write-Host "Error: Python venv not found at $BaseDir\venv" -ForegroundColor Red
        Write-Host "Run: cd base && python -m venv venv && .\venv\Scripts\Activate.ps1 && pip install -e ."
        exit 1
    }

    # Activate venv and build
    & $VenvActivate
    python scripts/build_binary.py --clean

    $ServerDist = Join-Path $BaseDir "dist\parachute-server"
    if (-not (Test-Path $ServerDist)) {
        Write-Host "Error: Server build failed" -ForegroundColor Red
        exit 1
    }

    Pop-Location
    Write-Host "Server build complete" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "Skipping server build (--SkipServer)" -ForegroundColor Yellow
    Write-Host ""
}

# Step 2: Build Flutter app
if (-not $SkipFlutter) {
    Write-Host "Step 2: Building Flutter app..." -ForegroundColor Blue
    Push-Location $AppDir

    flutter build windows --release

    $FlutterBundle = Join-Path $AppDir "build\windows\x64\runner\Release"
    if (-not (Test-Path $FlutterBundle)) {
        Write-Host "Error: Flutter build failed" -ForegroundColor Red
        exit 1
    }

    Pop-Location
    Write-Host "Flutter build complete" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host "Skipping Flutter build (--SkipFlutter)" -ForegroundColor Yellow
    Write-Host ""
}

# Step 3: Bundle together
Write-Host "Step 3: Creating bundled app..." -ForegroundColor Blue

$FlutterBundle = Join-Path $AppDir "build\windows\x64\runner\Release"
$BundledDir = Join-Path $DistDir "parachute-windows-x64"

if (-not (Test-Path $FlutterBundle)) {
    Write-Host "Error: Flutter bundle not found at $FlutterBundle" -ForegroundColor Red
    Write-Host "Build the Flutter app first or remove -SkipFlutter"
    exit 1
}

# Remove old bundled app if exists
if (Test-Path $BundledDir) {
    Remove-Item -Recurse -Force $BundledDir
}

# Copy Flutter bundle
Write-Host "  Copying Flutter bundle..."
Copy-Item -Recurse $FlutterBundle $BundledDir

# Copy server into data directory (standard location for Windows apps)
$ServerSrc = Join-Path $BaseDir "dist\parachute-server"
$ServerDest = Join-Path $BundledDir "data\parachute-server"

if (-not (Test-Path $ServerSrc)) {
    Write-Host "Error: Server binary not found at $ServerSrc" -ForegroundColor Red
    Write-Host "Build the server first or remove -SkipServer"
    exit 1
}

Write-Host "  Copying server binary..."
New-Item -ItemType Directory -Force -Path (Join-Path $BundledDir "data") | Out-Null
Copy-Item -Recurse $ServerSrc $ServerDest

# Create zip file
Write-Host "  Creating zip file..."
$ZipPath = Join-Path $DistDir "parachute-windows-x64.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath }
Compress-Archive -Path $BundledDir -DestinationPath $ZipPath

# Calculate sizes (approximate)
$FlutterSize = "{0:N2} MB" -f ((Get-ChildItem -Recurse $FlutterBundle | Measure-Object -Property Length -Sum).Sum / 1MB)
$ServerSize = "{0:N2} MB" -f ((Get-ChildItem -Recurse $ServerSrc | Measure-Object -Property Length -Sum).Sum / 1MB)
$BundleSize = "{0:N2} MB" -f ((Get-ChildItem -Recurse $BundledDir | Measure-Object -Property Length -Sum).Sum / 1MB)
$ZipSize = "{0:N2} MB" -f ((Get-Item $ZipPath).Length / 1MB)

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Flutter app:     $FlutterSize"
Write-Host "  Server binary:   $ServerSize"
Write-Host "  Bundled app:     $BundleSize"
Write-Host "  Zip file:        $ZipSize"
Write-Host ""
Write-Host "  Output: $ZipPath"
Write-Host ""
Write-Host "To run:" -ForegroundColor Blue
Write-Host "  1. Extract the zip file"
Write-Host "  2. Run parachute.exe"
Write-Host ""
