# Omi Device Firmware

This directory contains the firmware for the Omi wearable device that integrates with the Parachute recorder app.

## Overview

The firmware is built on **Zephyr RTOS** (v2.7.0) for the nRF52840 chip and provides:
- 🎙️ Audio capture with multiple codec support (PCM8/16, Opus, μLaw)
- 📡 Bluetooth Low Energy (BLE) communication
- 🔘 Smart button controls with tap detection
- 💡 LED status indicators
- 🔋 Battery and charging management
- 📦 Over-the-air (OTA) firmware updates

## Current Version

**DevKit v2**: 2.0.12

### Recent Changes (v2.0.12)
- ✅ Fixed button detection with 50ms debounce
- ✅ Corrected button logic (active LOW)
- ✅ Fixed LED priority (recording takes precedence)
- ✅ Microphone starts OFF (prevents auto-recording on boot)
- ✅ Implemented smart tap behavior

## Directory Structure

```
firmware/
├── devkit/              # Development kit firmware (Seeed XIAO nRF52840)
│   ├── src/            # Source files
│   │   ├── main.c      # Entry point, LED state management
│   │   ├── button.c    # Smart tap detection (18KB, most complex)
│   │   ├── mic.c       # Audio capture
│   │   ├── transport.c # BLE communication (28KB)
│   │   ├── codec.c     # Audio codec selection
│   │   ├── led.c       # LED control primitives
│   │   └── ...         # Other components
│   ├── overlay/        # Hardware pin configurations
│   └── prj_*.conf      # Build configuration files
├── boards/             # Custom board definitions
├── bootloader/         # MCUboot bootloader for OTA
└── scripts/            # Build and utility scripts
```

## Building the Firmware

### Prerequisites

**Option 1: Docker** (Recommended - no SDK install needed)
- Docker installed and running
- Works on macOS (including M1/M2/M3), Linux, Windows

**Option 2: Native Build**
- nRF Connect SDK v2.7.0
- Zephyr dependencies
- ARM GCC toolchain

### Quick Build (Docker)

```bash
cd firmware
./scripts/build-docker.sh
```

The compiled firmware will be at: `firmware/build/docker_build/zephyr.zip`

### Build and Integrate into App

This command builds firmware AND copies it to Flutter assets for OTA:

```bash
cd firmware
./scripts/build-and-integrate.sh
```

This will:
1. Build firmware with Docker
2. Copy to `assets/firmware/devkit-v2-firmware-VERSION.zip`
3. Create symlink to `devkit-v2-firmware-latest.zip`
4. Generate `BUILD_INFO.txt`

### Clean Build

```bash
cd firmware
./scripts/build-docker.sh --clean
# or
./scripts/build-and-integrate.sh --clean
```

## Flashing Firmware

### Via OTA (Recommended)
1. Build firmware: `./scripts/build-and-integrate.sh`
2. Run Flutter app: `flutter run`
3. Navigate to Settings → Omi Device → Pair device
4. Once connected, the app will detect new firmware and prompt for update

### Via USB (Direct Flash)
1. Put device in bootloader mode:
   - Double-tap reset button (green LED blinks)
   - Device appears as USB mass storage drive
2. Flash firmware:
   ```bash
   cd firmware/devkit
   ./flash.sh
   ```
3. Device will reboot with new firmware

### Via Serial Debugger (Development)
Requires J-Link or similar debugger - see Zephyr docs.

## Debugging

### Serial Monitor

```bash
cd firmware/scripts
./monitor_device.sh
```

This will show:
- Boot sequence
- Button events
- Recording state changes
- BLE connection status
- Error messages

### Enable Debug Logging

Edit `firmware/devkit/src/main.c` and uncomment debug lines:
```c
// Uncomment for debug output
#define DEBUG_ENABLED 1
```

Then rebuild firmware.

## Key Components Explained

### Button Behavior (`button.c`)

**Starting Recording**:
- Any tap (single/double/triple) starts recording
- LED turns RED
- Microphone powers on

**Stopping Recording**:
- Tap count determines recording type:
  - **1 tap**: Standard recording
  - **2 taps**: AI Query (app sends transcription to AI)
  - **3 taps**: Knowledge Capture (app extracts action items)
- LED turns BLUE (if connected) or OFF (if disconnected)
- Microphone powers off

**Long Press** (1 second):
- Powers off device

**Technical Details**:
- GPIO pin 5 (active LOW: 0=pressed, 1=released)
- Edge-triggered interrupts (both press and release)
- 50ms debounce window
- Recording state persists between taps

### LED States (`main.c`, `led.c`)

**Priority** (highest to lowest):
1. **RED**: Recording active
2. **BLUE**: Connected to app (only when not recording)
3. **GREEN**: Charging (blinks)

**State Logic**:
- If recording → RED on, BLUE off
- Else if connected → BLUE on, RED off
- Else → Both off
- Charging → GREEN blinks regardless

### Audio Codecs (`codec.c`)

**Supported Codecs**:
- **PCM8**: 8-bit PCM, 16kHz, ~128 kbps
- **PCM16**: 16-bit PCM, 16kHz, ~256 kbps (default)
- **Opus**: Compressed, 16kHz, ~24 kbps (best for BLE)
- **μLaw8**: 8-bit μ-law, 16kHz, ~128 kbps
- **μLaw16**: 16-bit μ-law, 16kHz, ~256 kbps

**Codec IDs** (must match app):
```c
1  = PCM8
10 = PCM16
20 = Opus
11 = μLaw8
12 = μLaw16
```

### BLE Communication (`transport.c`)

**GATT Services**:
- Device Information Service (DIS)
- Audio Service (custom UUID: `19B10000-E8F2-537E-4F6C-D104768A1214`)
- Button Service (button events)

**Audio Streaming**:
- Audio frames sent via BLE notifications
- Packet format: `[frame_index_low, frame_index_high, frameId, ...audio_data]`
- App assembles packets into WAV file

**Button Events**:
- Single/double/triple tap events sent to app
- App uses tap count to categorize recording

## Development Workflow

### 1. Make Changes

Edit source files in `firmware/devkit/src/`:
```bash
vim firmware/devkit/src/button.c
```

### 2. Update Version (if needed)

Edit `firmware/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf`:
```conf
CONFIG_BT_DIS_FW_REV_STR="2.0.13"
```

**Version Guidelines**:
- **MAJOR.MINOR.PATCH**
- MAJOR: Breaking BLE protocol changes
- MINOR: New features, compatible with app
- PATCH: Bug fixes

### 3. Build and Test

```bash
cd firmware
./scripts/build-and-integrate.sh
```

### 4. Test on Device

**Option A**: Flash via USB
```bash
cd firmware/devkit
./flash.sh
```

**Option B**: Test OTA in app
```bash
cd ../..  # Back to project root
flutter run
# Navigate to Settings → Omi Device → Update Firmware
```

### 5. Verify Changes

- Check serial output: `./firmware/scripts/monitor_device.sh`
- Test button behavior
- Check LED states
- Test audio recording
- Verify BLE communication

### 6. Commit

```bash
# Commit firmware source AND compiled binary together
git add firmware/ assets/firmware/
git commit -m "firmware: Fix button debouncing (v2.0.13)"

# Tag release
git tag firmware-v2.0.13
```

## Creating Patches

When fixing bugs, create patches for easy distribution:

```bash
cd firmware/devkit
git diff > ../fix_my_feature.patch

# To apply patch later:
git apply ../fix_my_feature.patch
```

## Common Issues

### Build Fails
- **Docker not running**: Start Docker Desktop
- **Platform issues**: Add `--clean` flag for clean build
- **Permissions**: Ensure scripts are executable (`chmod +x scripts/*.sh`)

### Device Won't Flash
- **Bootloader mode**: Double-tap reset, green LED should blink
- **USB cable**: Try different cable (must support data, not just power)
- **Driver issues**: Install nRF USB driver (Windows)

### Button Not Working
- **Debounce**: Check 50ms debounce in `button.c`
- **GPIO config**: Verify `GPIO_INT_EDGE_BOTH` in button init
- **Active LOW**: Button press = 0, release = 1
- **Serial debug**: Monitor button callbacks

### Auto-Recording on Boot
- **Mic init**: Ensure `nrfy_gpio_pin_clear(PDM_PWR_PIN)` in `mic.c`
- **Recording state**: Check `is_recording = false` in main init

### LED States Wrong
- **Priority**: Recording (red) must override connected (blue)
- **State machine**: Check `set_led_state()` in `main.c`
- **Global state**: Ensure `is_recording_global` is updated

## Integration with Parachute App

### App Assets

Compiled firmware is stored in:
```
assets/firmware/
├── devkit-v2-firmware-2.0.12.zip  # Version-specific
├── devkit-v2-firmware-latest.zip  # Symlink to latest
└── BUILD_INFO.txt                  # Build metadata
```

### OTA Update Flow

1. App connects to device via BLE
2. App reads firmware version from Device Information Service
3. If app has newer firmware, prompts user to update
4. App initiates Nordic DFU protocol
5. Device reboots into bootloader
6. App transfers new firmware
7. Device validates and installs firmware
8. Device reboots with new firmware

### BLE Protocol Compatibility

**Current Protocol Version**: 2.x

- **2.x**: Smart tap behavior, multiple codecs
- **Future 3.x**: May add new GATT characteristics

The app must remain compatible with firmware versions it bundles.

## Further Reading

- [Zephyr RTOS Docs](https://docs.zephyrproject.org/)
- [nRF Connect SDK](https://developer.nordicsemi.com/nRF_Connect_SDK/)
- [Nordic DFU](https://infocenter.nordicsemi.com/topic/sdk_nrf5_v17.1.0/lib_dfu_transport.html)
- [Seeed XIAO nRF52840](https://wiki.seeedstudio.com/XIAO_BLE/)

## Support

For firmware issues:
1. Check serial output for errors
2. Review recent changes in git log
3. Test with clean build
4. Check hardware connections
5. File issue in project repository

## License

This firmware inherits the license from the original Omi project.
