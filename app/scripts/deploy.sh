#!/bin/bash
# Deploy APK to connected ADB device
# Usage:
#   ./scripts/deploy.sh              # Build and install debug APK
#   ./scripts/deploy.sh --release    # Build and install release APK
#   ./scripts/deploy.sh --install    # Install only (skip build)
#   ./scripts/deploy.sh --connect 192.168.1.100:5555  # Connect wirelessly first

set -e

cd "$(dirname "$0")/.."

BUILD_TYPE="debug"
SKIP_BUILD=false
CONNECT_ADDR=""
FLAVOR="full"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --release|-r)
            BUILD_TYPE="release"
            shift
            ;;
        --install|-i)
            SKIP_BUILD=true
            shift
            ;;
        --connect|-c)
            CONNECT_ADDR="$2"
            shift 2
            ;;
        --daily)
            FLAVOR="daily"
            shift
            ;;
        --help|-h)
            echo "Usage: ./scripts/deploy.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --release, -r          Build release APK (default: debug)"
            echo "  --install, -i          Install only, skip build"
            echo "  --connect, -c ADDR     Connect to device wirelessly (e.g., 192.168.1.100:5555)"
            echo "  --daily                Use daily flavor instead of full"
            echo "  --help, -h             Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Connect wirelessly if address provided
if [[ -n "$CONNECT_ADDR" ]]; then
    echo "Connecting to $CONNECT_ADDR..."
    adb connect "$CONNECT_ADDR"
    sleep 1
fi

# Check for connected device
if ! adb devices | grep -q "device$"; then
    echo "Error: No ADB device connected"
    echo "Connect a device via USB or use --connect <ip:port> for wireless"
    exit 1
fi

DEVICE=$(adb devices | grep "device$" | head -1 | cut -f1)
echo "Target device: $DEVICE"

# Determine APK path
APK_PATH="build/app/outputs/flutter-apk/app-${FLAVOR}-${BUILD_TYPE}.apk"

# Build if needed
if [[ "$SKIP_BUILD" == false ]]; then
    echo "Building $FLAVOR $BUILD_TYPE APK..."
    flutter build apk --$BUILD_TYPE --flavor $FLAVOR
fi

# Check APK exists
if [[ ! -f "$APK_PATH" ]]; then
    echo "Error: APK not found at $APK_PATH"
    echo "Run without --install to build first"
    exit 1
fi

# Install
echo "Installing $APK_PATH..."
adb -s "$DEVICE" install -r "$APK_PATH"

echo "Done! Installed to $DEVICE"
