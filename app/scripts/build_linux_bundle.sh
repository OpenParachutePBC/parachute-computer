#!/bin/bash
#
# Build script for Parachute Computer (Linux)
#
# This script:
# 1. Builds the Python server binary using PyInstaller
# 2. Builds the Flutter Linux app
# 3. Bundles them together into a tarball
#
# Usage:
#   cd app && ./scripts/build_linux_bundle.sh [--skip-server] [--skip-flutter] [--clean]
#
# Environment:
#   PARACHUTE_BASE_DIR - Path to base server (default: ../base)
#
# Output:
#   app/dist/parachute-linux-x64.tar.gz
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
echo -e "${BLUE}  Parachute Computer - Linux Build${NC}"
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

    flutter build linux --release

    if [ ! -d "build/linux/x64/release/bundle" ]; then
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

# Flutter Linux build output
FLUTTER_BUNDLE="$APP_DIR/build/linux/x64/release/bundle"
BUNDLED_DIR="$DIST_DIR/parachute-linux-x64"

if [ ! -d "$FLUTTER_BUNDLE" ]; then
    echo -e "${RED}Error: Flutter bundle not found at $FLUTTER_BUNDLE${NC}"
    echo "Build the Flutter app first or remove --skip-flutter"
    exit 1
fi

# Remove old bundled app if exists
rm -rf "$BUNDLED_DIR"

# Copy Flutter bundle
echo "  Copying Flutter bundle..."
cp -R "$FLUTTER_BUNDLE" "$BUNDLED_DIR"

# Copy server into lib directory (standard location for Linux apps)
SERVER_SRC="$BASE_DIR/dist/parachute-server"
SERVER_DEST="$BUNDLED_DIR/lib/parachute-server"

if [ ! -d "$SERVER_SRC" ]; then
    echo -e "${RED}Error: Server binary not found at $SERVER_SRC${NC}"
    echo "Build the server first or remove --skip-server"
    exit 1
fi

echo "  Copying server binary..."
mkdir -p "$BUNDLED_DIR/lib"
cp -R "$SERVER_SRC" "$SERVER_DEST"

# Make server executable
chmod +x "$SERVER_DEST/parachute-server"
chmod +x "$SERVER_DEST/parachute-mcp"

# Create launcher script
echo "  Creating launcher script..."
cat > "$BUNDLED_DIR/parachute.sh" << 'LAUNCHER'
#!/bin/bash
# Parachute launcher script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:$LD_LIBRARY_PATH"
exec "$SCRIPT_DIR/parachute" "$@"
LAUNCHER
chmod +x "$BUNDLED_DIR/parachute.sh"

# Create .desktop file for desktop integration
echo "  Creating desktop entry..."
cat > "$BUNDLED_DIR/parachute.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Parachute
Comment=Local-first, voice-first extended mind
Exec=parachute
Icon=parachute
Type=Application
Categories=Utility;Office;
Terminal=false
DESKTOP

# Create tarball
echo "  Creating tarball..."
cd "$DIST_DIR"
tar -czvf "parachute-linux-x64.tar.gz" "parachute-linux-x64"

# Calculate sizes
FLUTTER_SIZE=$(du -sh "$FLUTTER_BUNDLE" | cut -f1)
SERVER_SIZE=$(du -sh "$SERVER_SRC" | cut -f1)
BUNDLE_SIZE=$(du -sh "$BUNDLED_DIR" | cut -f1)
TARBALL_SIZE=$(du -sh "$DIST_DIR/parachute-linux-x64.tar.gz" | cut -f1)

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "  Flutter app:     $FLUTTER_SIZE"
echo "  Server binary:   $SERVER_SIZE"
echo "  Bundled app:     $BUNDLE_SIZE"
echo "  Tarball:         $TARBALL_SIZE"
echo ""
echo "  Output: $DIST_DIR/parachute-linux-x64.tar.gz"
echo ""
echo -e "${BLUE}To install:${NC}"
echo "  tar -xzvf parachute-linux-x64.tar.gz"
echo "  cd parachute-linux-x64"
echo "  ./parachute.sh"
echo ""
echo -e "${BLUE}For system-wide install:${NC}"
echo "  sudo cp -r parachute-linux-x64 /opt/parachute"
echo "  sudo ln -s /opt/parachute/parachute.sh /usr/local/bin/parachute"
echo ""
