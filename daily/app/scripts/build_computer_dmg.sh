#!/bin/bash
# Build script for Parachute Computer (.dmg distribution)
#
# This creates a distributable .dmg with:
# - Parachute.app (Flutter app built with FLAVOR=computer)
# - Bundled Parachute Computer (Python server)
#
# Prerequisites:
# - Flutter SDK
# - create-dmg (brew install create-dmg)
#
# Usage:
#   cd app && ./scripts/build_computer_dmg.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$APP_DIR")"
COMPUTER_DIR="$PROJECT_ROOT/computer"
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

echo "╔══════════════════════════════════════════════════════╗"
echo "║        Building Parachute Computer                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Clean previous build
echo "→ Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build Flutter app with computer flavor (if not already built)
APP_BUILD_PATH="$APP_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
if [ -d "$APP_BUILD_PATH" ] && [ "$SKIP_BUILD" = "true" ]; then
  echo "→ Using existing app build..."
else
  echo "→ Building Flutter app (FLAVOR=computer)..."
  cd "$APP_DIR"
  flutter build macos --release --dart-define=FLAVOR=computer
fi

# Copy app to build directory
echo "→ Copying app bundle..."
cp -R "$APP_BUILD_PATH" "$BUILD_DIR/"

# Create Resources directory structure
RESOURCES_DIR="$BUILD_DIR/$APP_NAME.app/Contents/Resources"
mkdir -p "$RESOURCES_DIR/computer"

# Bundle Parachute Computer (excluding venv, __pycache__, etc.)
echo "→ Bundling Parachute Computer..."
rsync -av --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.pytest_cache' --exclude='*.egg-info' --exclude='.git' \
  "$COMPUTER_DIR/" "$RESOURCES_DIR/computer/"

# Create install helper script
echo "→ Creating install helper..."
cat > "$RESOURCES_DIR/install-computer.sh" << 'EOF'
#!/bin/bash
# Installs Parachute Computer to the vault if not present
# Called by the app on first run

VAULT_PATH="${1:-$HOME/Parachute}"
COMPUTER_DEST="$VAULT_PATH/projects/parachute/computer"

if [ ! -d "$COMPUTER_DEST" ]; then
  echo "Installing Parachute Computer to $COMPUTER_DEST..."
  mkdir -p "$(dirname "$COMPUTER_DEST")"
  cp -R "$(dirname "$0")/computer" "$COMPUTER_DEST"
  echo "Parachute Computer installed."
else
  echo "Parachute Computer already exists at $COMPUTER_DEST"
fi
EOF
chmod +x "$RESOURCES_DIR/install-computer.sh"

# Code signing (if CODESIGN_IDENTITY is set)
if [ -n "$CODESIGN_IDENTITY" ]; then
  echo "→ Signing app bundle with: $CODESIGN_IDENTITY"

  ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"
  BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"

  # Sign all .so and .dylib files in Resources (bundled Python binaries, etc.)
  echo "  Signing bundled binaries in Resources..."
  find "$BUNDLE_PATH/Contents/Resources" -type f \( -name "*.so" -o -name "*.dylib" \) 2>/dev/null | while read -r file; do
    echo "    Signing: $(basename "$file")"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$file" || true
  done

  # Sign all nested frameworks and dylibs in Frameworks
  find "$BUNDLE_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) 2>/dev/null | while read -r file; do
    echo "  Signing: $file"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$file" 2>/dev/null || true
  done

  # Sign framework bundles
  find "$BUNDLE_PATH/Contents/Frameworks" -name "*.framework" -type d 2>/dev/null | while read -r framework; do
    echo "  Signing framework: $framework"
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$framework" 2>/dev/null || true
  done

  # Sign the main app bundle with hardened runtime
  echo "  Signing main bundle..."
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$CODESIGN_IDENTITY" \
    "$BUNDLE_PATH"

  # Verify
  echo "  Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "$BUNDLE_PATH"
  echo "✓ Code signing complete"
else
  echo "→ Skipping code signing (CODESIGN_IDENTITY not set)"
fi

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
