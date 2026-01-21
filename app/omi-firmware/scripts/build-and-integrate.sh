#!/bin/bash
set -euo pipefail

# Script to build firmware and automatically integrate it into Flutter app assets
# This ensures the app always has the latest firmware for OTA updates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$FIRMWARE_DIR/.." && pwd)"
ASSETS_DIR="$PROJECT_ROOT/assets/firmware"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to extract firmware version from config
get_firmware_version() {
    local config_file="$FIRMWARE_DIR/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf"
    if [ -f "$config_file" ]; then
        grep "CONFIG_BT_DIS_FW_REV_STR" "$config_file" | cut -d'"' -f2
    else
        echo "2.0.12" # Fallback version
    fi
}

# Function to print status
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[i]${NC} $1"
}

# Main build process
main() {
    local clean_build=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                clean_build=true
                shift
                ;;
            *)
                echo "Usage: $0 [--clean]"
                exit 1
                ;;
        esac
    done

    print_info "Starting firmware build and integration process..."

    # Get firmware version
    FIRMWARE_VERSION=$(get_firmware_version)
    print_status "Detected firmware version: $FIRMWARE_VERSION"

    # Build firmware
    print_info "Building firmware..."
    cd "$FIRMWARE_DIR"

    if [ "$clean_build" = true ]; then
        print_info "Performing clean build..."
        ./scripts/build-docker-fixed.sh --clean
    else
        ./scripts/build-docker-fixed.sh
    fi

    # Check if build was successful
    BUILD_OUTPUT="$FIRMWARE_DIR/build/docker_build/zephyr.zip"
    if [ ! -f "$BUILD_OUTPUT" ]; then
        print_error "Firmware build failed! Expected output not found: $BUILD_OUTPUT"
        exit 1
    fi

    print_status "Firmware built successfully"

    # Verify the ZIP file is valid
    if ! unzip -t "$BUILD_OUTPUT" >/dev/null 2>&1; then
        print_error "Generated firmware ZIP is corrupted!"
        exit 1
    fi

    print_status "Firmware ZIP validated"

    # Ensure assets directory exists
    mkdir -p "$ASSETS_DIR"

    # Copy firmware to assets with version-specific name
    DEST_FILE="$ASSETS_DIR/devkit-v2-firmware-${FIRMWARE_VERSION}.zip"
    cp "$BUILD_OUTPUT" "$DEST_FILE"

    if [ -f "$DEST_FILE" ]; then
        print_status "Firmware copied to: $DEST_FILE"

        # Show file size for verification
        SIZE=$(ls -lh "$DEST_FILE" | awk '{print $5}')
        print_info "Firmware size: $SIZE"
    else
        print_error "Failed to copy firmware to assets!"
        exit 1
    fi

    # Update firmware reference in device provider if needed
    DEVICE_PROVIDER="$PROJECT_ROOT/lib/providers/device_provider.dart"
    if [ -f "$DEVICE_PROVIDER" ]; then
        # Check if the firmware file reference needs updating
        CURRENT_REF=$(grep -o 'devkit-v2-firmware-[0-9.]*\.zip' "$DEVICE_PROVIDER" || true)
        EXPECTED_REF="devkit-v2-firmware-${FIRMWARE_VERSION}.zip"

        if [ "$CURRENT_REF" != "$EXPECTED_REF" ] && [ -n "$CURRENT_REF" ]; then
            print_info "Updating firmware reference in device_provider.dart..."
            sed -i.bak "s/$CURRENT_REF/$EXPECTED_REF/g" "$DEVICE_PROVIDER"
            rm -f "$DEVICE_PROVIDER.bak"
            print_status "Updated firmware reference to: $EXPECTED_REF"
        fi
    fi

    # Create a symlink for easy reference (always points to latest)
    LATEST_LINK="$ASSETS_DIR/devkit-v2-firmware-latest.zip"
    ln -sf "devkit-v2-firmware-${FIRMWARE_VERSION}.zip" "$LATEST_LINK"
    print_status "Created symlink for latest firmware"

    # Generate build info
    BUILD_INFO="$ASSETS_DIR/BUILD_INFO.txt"
    cat > "$BUILD_INFO" << EOF
Firmware Build Information
========================
Version: $FIRMWARE_VERSION
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Build Host: $(hostname)
Git Commit: $(cd "$FIRMWARE_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
Git Branch: $(cd "$FIRMWARE_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
EOF

    print_status "Generated build info"

    # Summary
    echo
    print_status "Firmware build and integration completed successfully!"
    echo
    echo "Next steps:"
    echo "1. Test the firmware update in the Flutter app"
    echo "2. Commit the new firmware file: git add $DEST_FILE"
    echo "3. Push changes to repository"
    echo
    echo "Firmware location: $DEST_FILE"
}

# Run main function
main "$@"
