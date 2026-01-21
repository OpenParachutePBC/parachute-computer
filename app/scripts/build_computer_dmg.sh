#!/bin/bash
# Build script for Parachute Computer (.dmg distribution)
#
# This creates a distributable .dmg with:
# - Parachute.app (Flutter app built with FLAVOR=computer)
# - Bundled Lima config
# - Bundled base server (raw Python, runs in Lima VM)
#
# Prerequisites:
# - Flutter SDK
# - create-dmg (brew install create-dmg)
#
# Usage:
#   cd app && ./scripts/build_computer_dmg.sh
#
# Developer usage (custom base path for Lima to mount):
#   cd app && ./scripts/build_computer_dmg.sh --dev-base-path ~/Parachute/projects/parachute/base
#
# The --dev-base-path option creates a Lima config that mounts your local base
# instead of ~/Library/Application Support/Parachute/base

set -e

# Parse arguments
DEV_BASE_PATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --dev-base-path)
      DEV_BASE_PATH="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$APP_DIR")"
BASE_DIR="$PROJECT_ROOT/base"
LIMA_DIR="$APP_DIR/lima"
DIST_DIR="$APP_DIR/dist"
BUILD_DIR="$DIST_DIR/computer-build"

# Extract version from pubspec.yaml (format: version: 1.0.0+1)
# Takes only the version part before the + (build number)
VERSION=$(grep '^version:' "$APP_DIR/pubspec.yaml" | sed 's/version: //' | cut -d'+' -f1)
if [ -z "$VERSION" ]; then
  echo "Error: Could not extract version from pubspec.yaml"
  exit 1
fi

APP_NAME="Parachute"
DMG_NAME="ParachuteComputer-$VERSION"

if [ -n "$DEV_BASE_PATH" ]; then
  echo "Developer mode: using custom base path: $DEV_BASE_PATH"
  DMG_NAME="ParachuteComputer-$VERSION-dev"
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║        Building Parachute Computer                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Clean previous build
echo "→ Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build Flutter app with computer flavor (if not already built)
APP_BUILD_PATH="$APP_DIR/build/macos/Build/Products/Release-computer/$APP_NAME.app"
if [ -d "$APP_BUILD_PATH" ] && [ "$SKIP_BUILD" = "true" ]; then
  echo "→ Using existing app build..."
else
  echo "→ Building Flutter app (FLAVOR=computer)..."
  cd "$APP_DIR"
  flutter build macos --release --flavor computer
fi

# Copy app to build directory
echo "→ Copying app bundle..."
cp -R "$APP_BUILD_PATH" "$BUILD_DIR/"

# Create Resources directory structure
RESOURCES_DIR="$BUILD_DIR/$APP_NAME.app/Contents/Resources"
mkdir -p "$RESOURCES_DIR/lima"
mkdir -p "$RESOURCES_DIR/base"

# Bundle Lima config
echo "→ Bundling Lima configuration..."
if [ -n "$DEV_BASE_PATH" ]; then
  # Developer mode: modify Lima config to mount custom base path
  echo "  Configuring Lima for developer base path: $DEV_BASE_PATH"
  sed "s|~/Library/Application Support/Parachute/base|$DEV_BASE_PATH|g" \
    "$LIMA_DIR/parachute.yaml" > "$RESOURCES_DIR/lima/parachute.yaml"
else
  cp "$LIMA_DIR/parachute.yaml" "$RESOURCES_DIR/lima/"
fi
cp "$LIMA_DIR/setup.sh" "$RESOURCES_DIR/lima/" 2>/dev/null || true

# Bundle base server (excluding venv, __pycache__, etc.)
# In developer mode, we still bundle base for reference but the VM uses the mounted path
echo "→ Bundling base server..."
rsync -av --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.pytest_cache' --exclude='*.egg-info' --exclude='.git' \
  "$BASE_DIR/" "$RESOURCES_DIR/base/"

# Create install helper script
echo "→ Creating install helper..."
cat > "$RESOURCES_DIR/install-base.sh" << 'EOF'
#!/bin/bash
# Installs the base server to the vault if not present
# Called by the app on first run

VAULT_PATH="${1:-$HOME/Parachute}"
BASE_DEST="$VAULT_PATH/projects/parachute/base"

if [ ! -d "$BASE_DEST" ]; then
  echo "Installing Parachute base server to $BASE_DEST..."
  mkdir -p "$(dirname "$BASE_DEST")"
  cp -R "$(dirname "$0")/base" "$BASE_DEST"
  echo "Base server installed."
else
  echo "Base server already exists at $BASE_DEST"
fi
EOF
chmod +x "$RESOURCES_DIR/install-base.sh"

# Check if create-dmg is installed
if ! command -v create-dmg &> /dev/null; then
  echo ""
  echo "⚠️  create-dmg not installed. Skipping .dmg creation."
  echo "   Install with: brew install create-dmg"
  echo ""
  echo "✓ App bundle ready at: $BUILD_DIR/$APP_NAME.app"
  exit 0
fi

# Create DMG
echo "→ Creating .dmg..."
mkdir -p "$DIST_DIR"

# Remove old DMG if exists
rm -f "$DIST_DIR/$DMG_NAME.dmg"

create-dmg \
  --volname "$APP_NAME" \
  --volicon "$APP_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 150 185 \
  --app-drop-link 450 185 \
  --hide-extension "$APP_NAME.app" \
  "$DIST_DIR/$DMG_NAME.dmg" \
  "$BUILD_DIR/$APP_NAME.app" \
  || {
    # create-dmg returns non-zero even on success sometimes
    if [ -f "$DIST_DIR/$DMG_NAME.dmg" ]; then
      echo "DMG created (with warnings)"
    else
      echo "Failed to create DMG"
      exit 1
    fi
  }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Build Complete!                               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  App:  $BUILD_DIR/$APP_NAME.app"
echo "  DMG:  $DIST_DIR/$DMG_NAME.dmg"
echo ""
echo "To test:"
echo "  open \"$BUILD_DIR/$APP_NAME.app\""
echo ""
