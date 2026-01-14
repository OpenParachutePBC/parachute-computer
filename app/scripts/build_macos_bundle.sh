#!/bin/bash
#
# Build script for Parachute Computer (macOS)
#
# This script:
# 1. Builds the Python server binary using PyInstaller
# 2. Builds the Flutter macOS app
# 3. Bundles them together into a complete app package
#
# Usage:
#   cd app && ./scripts/build_macos_bundle.sh [--skip-server] [--skip-flutter] [--clean]
#
# Environment:
#   PARACHUTE_BASE_DIR - Path to base server (default: ../base)
#
# Output:
#   app/dist/Parachute.app - Complete bundled application
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BASE_DIR="${PARACHUTE_BASE_DIR:-$(dirname "$APP_DIR")/base}"
DIST_DIR="$APP_DIR/dist"

# Parse arguments
SKIP_SERVER=false
SKIP_FLUTTER=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --skip-server)
            SKIP_SERVER=true
            shift
            ;;
        --skip-flutter)
            SKIP_FLUTTER=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            ;;
    esac
done

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Parachute Computer - macOS Build${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Show paths
echo "  App dir:    $APP_DIR"
echo "  Base dir:   $BASE_DIR"
echo "  Output:     $DIST_DIR"
echo ""

# Clean if requested
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}Cleaning previous builds...${NC}"
    rm -rf "$DIST_DIR"
    rm -rf "$BASE_DIR/build" "$BASE_DIR/dist"
    rm -rf "$APP_DIR/build"
    echo -e "${GREEN}Clean complete${NC}"
    echo ""
fi

# Create dist directory
mkdir -p "$DIST_DIR"

# Step 1: Build Python server
if [ "$SKIP_SERVER" = false ]; then
    echo -e "${BLUE}Step 1: Building Python server...${NC}"
    cd "$BASE_DIR"

    # Activate venv if it exists
    if [ -f "venv/bin/activate" ]; then
        source venv/bin/activate
    else
        echo -e "${RED}Error: Python venv not found at $BASE_DIR/venv${NC}"
        echo "Run: cd base && python3 -m venv venv && source venv/bin/activate && pip install -e ."
        exit 1
    fi

    # Build with PyInstaller
    python scripts/build_binary.py --clean

    if [ ! -d "dist/parachute-server" ]; then
        echo -e "${RED}Error: Server build failed${NC}"
        exit 1
    fi

    echo -e "${GREEN}Server build complete${NC}"
    echo ""
else
    echo -e "${YELLOW}Skipping server build (--skip-server)${NC}"
    echo ""
fi

# Step 2: Build Flutter app
if [ "$SKIP_FLUTTER" = false ]; then
    echo -e "${BLUE}Step 2: Building Flutter app...${NC}"
    cd "$APP_DIR"

    flutter build macos --release

    if [ ! -d "build/macos/Build/Products/Release/parachute.app" ]; then
        echo -e "${RED}Error: Flutter build failed${NC}"
        exit 1
    fi

    echo -e "${GREEN}Flutter build complete${NC}"
    echo ""
else
    echo -e "${YELLOW}Skipping Flutter build (--skip-flutter)${NC}"
    echo ""
fi

# Step 3: Bundle together
echo -e "${BLUE}Step 3: Creating bundled app...${NC}"

# Copy Flutter app to dist
FLUTTER_APP="$APP_DIR/build/macos/Build/Products/Release/parachute.app"
BUNDLED_APP="$DIST_DIR/Parachute.app"

if [ ! -d "$FLUTTER_APP" ]; then
    echo -e "${RED}Error: Flutter app not found at $FLUTTER_APP${NC}"
    echo "Build the Flutter app first or remove --skip-flutter"
    exit 1
fi

# Remove old bundled app if exists
rm -rf "$BUNDLED_APP"

# Copy Flutter app
echo "  Copying Flutter app..."
cp -R "$FLUTTER_APP" "$BUNDLED_APP"

# Copy server into Resources
SERVER_SRC="$BASE_DIR/dist/parachute-server"
SERVER_DEST="$BUNDLED_APP/Contents/Resources/parachute-server"

if [ ! -d "$SERVER_SRC" ]; then
    echo -e "${RED}Error: Server binary not found at $SERVER_SRC${NC}"
    echo "Build the server first or remove --skip-server"
    exit 1
fi

echo "  Copying server binary..."
cp -R "$SERVER_SRC" "$SERVER_DEST"

# Make server executable
chmod +x "$SERVER_DEST/parachute-server"
chmod +x "$SERVER_DEST/parachute-mcp"

# Update Info.plist to mark as background capable (for server process)
echo "  Updating Info.plist..."
/usr/libexec/PlistBuddy -c "Add :LSBackgroundOnly bool false" "$BUNDLED_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSSupportsAutomaticTermination bool false" "$BUNDLED_APP/Contents/Info.plist" 2>/dev/null || true

# Calculate sizes
FLUTTER_SIZE=$(du -sh "$FLUTTER_APP" | cut -f1)
SERVER_SIZE=$(du -sh "$SERVER_SRC" | cut -f1)
BUNDLE_SIZE=$(du -sh "$BUNDLED_APP" | cut -f1)

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Flutter app:     $FLUTTER_SIZE"
echo "  Server binary:   $SERVER_SIZE"
echo "  Bundled app:     $BUNDLE_SIZE"
echo ""
echo "  Output: $BUNDLED_APP"
echo ""
echo -e "${BLUE}To run:${NC}"
echo "  open \"$BUNDLED_APP\""
echo ""
echo -e "${BLUE}To create DMG:${NC}"
echo "  hdiutil create -volname Parachute -srcfolder \"$BUNDLED_APP\" -ov -format UDZO \"$DIST_DIR/Parachute.dmg\""
echo ""
