import 'package:flutter/foundation.dart';

/// BLE Service and Characteristic UUIDs for Omi Device
///
/// These UUIDs define the Bluetooth Low Energy services and characteristics
/// used to communicate with the Omi wearable device.

// Main Omi service UUID
const String omiServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';

// Audio streaming characteristics
const String audioDataStreamCharacteristicUuid =
    '19b10001-e8f2-537e-4f6c-d104768a1214';
const String audioCodecCharacteristicUuid =
    '19b10002-e8f2-537e-4f6c-d104768a1214';

// Button service (for recording start/stop)
const String buttonServiceUuid = '23ba7924-0000-1000-7450-346eac492e92';
const String buttonTriggerCharacteristicUuid =
    '23ba7925-0000-1000-7450-346eac492e92';

// Image capture service (for OpenGlass devices)
const String imageServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String imageDataStreamCharacteristicUuid =
    '19b10005-e8f2-537e-4f6c-d104768a1214';
const String imageCaptureControlCharacteristicUuid =
    '19b10006-e8f2-537e-4f6c-d104768a1214';

// Storage service (for device storage access)
const String storageDataStreamServiceUuid =
    '30295780-4301-eabd-2904-2849adfeae43';
const String storageDataStreamCharacteristicUuid =
    '30295781-4301-eabd-2904-2849adfeae43';
const String storageReadControlCharacteristicUuid =
    '30295782-4301-eabd-2904-2849adfeae43';

// Accelerometer service
const String accelDataStreamServiceUuid =
    '32403790-0000-1000-7450-bf445e5829a2';
const String accelDataStreamCharacteristicUuid =
    '32403791-0000-1000-7450-bf445e5829a2';

// Battery service (standard Bluetooth SIG UUID)
const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String batteryLevelCharacteristicUuid =
    '00002a19-0000-1000-8000-00805f9b34fb';

// Speaker service (for audio playback to device)
const String speakerDataStreamServiceUuid =
    'cab1ab95-2ea5-4f4d-bb56-874b72cfc984';
const String speakerDataStreamCharacteristicUuid =
    'cab1ab96-2ea5-4f4d-bb56-874b72cfc984';

// Device Information Service (standard Bluetooth SIG UUID)
const String deviceInformationServiceUuid =
    '0000180a-0000-1000-8000-00805f9b34fb';
const String modelNumberCharacteristicUuid =
    '00002a24-0000-1000-8000-00805f9b34fb';
const String firmwareRevisionCharacteristicUuid =
    '00002a26-0000-1000-8000-00805f9b34fb';
const String hardwareRevisionCharacteristicUuid =
    '00002a27-0000-1000-8000-00805f9b34fb';
const String manufacturerNameCharacteristicUuid =
    '00002a29-0000-1000-8000-00805f9b34fb';

// Frame device service UUID (for Frame smart glasses)
const String frameServiceUuid = "7A230001-5475-A6A4-654C-8431F6AD49C4";

/// Audio codec types supported by Omi device
enum BleAudioCodec {
  pcm8, // 8-bit PCM
  pcm16, // 16-bit PCM (recommended)
  mulaw8, // 8-bit mu-law
  mulaw16, // 16-bit mu-law
  opus, // Opus codec (highest quality, compressed)
  unknown;

  @override
  String toString() => mapCodecToName(this);
}

/// Map codec enum to string name
String mapCodecToName(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opus:
      return 'opus';
    case BleAudioCodec.pcm16:
      return 'pcm16';
    case BleAudioCodec.pcm8:
      return 'pcm8';
    case BleAudioCodec.mulaw16:
      return 'mulaw16';
    case BleAudioCodec.mulaw8:
      return 'mulaw8';
    default:
      return 'pcm8';
  }
}

/// Map string name to codec enum
BleAudioCodec mapNameToCodec(String codec) {
  switch (codec.toLowerCase()) {
    case 'opus':
      return BleAudioCodec.opus;
    case 'pcm16':
      return BleAudioCodec.pcm16;
    case 'pcm8':
      return BleAudioCodec.pcm8;
    case 'mulaw16':
      return BleAudioCodec.mulaw16;
    case 'mulaw8':
      return BleAudioCodec.mulaw8;
    default:
      return BleAudioCodec.pcm8;
  }
}

/// Get sample rate for codec
int mapCodecToSampleRate(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opus:
      return 16000; // 16kHz
    case BleAudioCodec.pcm16:
      return 16000;
    case BleAudioCodec.pcm8:
      return 16000;
    case BleAudioCodec.mulaw16:
      return 16000;
    case BleAudioCodec.mulaw8:
      return 16000;
    default:
      return 16000;
  }
}

/// Get bit depth for codec
int mapCodecToBitDepth(BleAudioCodec codec) {
  switch (codec) {
    case BleAudioCodec.opus:
      return 16;
    case BleAudioCodec.pcm16:
      return 16;
    case BleAudioCodec.pcm8:
      return 8;
    case BleAudioCodec.mulaw16:
      return 16;
    case BleAudioCodec.mulaw8:
      return 8;
    default:
      return 16;
  }
}

/// Device type enumeration
enum DeviceType {
  omi, // Standard Omi device
  openglass, // OpenGlass device with camera
  frame, // Frame smart glasses
}

/// Connection state for device
enum DeviceConnectionState {
  connected,
  disconnected,
  connecting,
}

/// Button event codes from device
enum ButtonEvent {
  singleTap, // Single button press (code 1)
  doubleTap, // Double button press (code 2)
  tripleTap, // Triple button press (code 3)
  buttonPressed, // Button pressed down (code 4)
  buttonReleased, // Button released (code 5)
  unknown;

  static ButtonEvent fromCode(int code) {
    switch (code) {
      case 1:
        return ButtonEvent.singleTap;
      case 2:
        return ButtonEvent.doubleTap;
      case 3:
        return ButtonEvent.tripleTap;
      case 4:
        return ButtonEvent.buttonPressed;
      case 5:
        return ButtonEvent.buttonReleased;
      default:
        return ButtonEvent.unknown;
    }
  }

  int toCode() {
    switch (this) {
      case ButtonEvent.singleTap:
        return 1;
      case ButtonEvent.doubleTap:
        return 2;
      case ButtonEvent.tripleTap:
        return 3;
      case ButtonEvent.buttonPressed:
        return 4;
      case ButtonEvent.buttonReleased:
        return 5;
      default:
        return 0;
    }
  }
}

/// Helper function to log errors
void logCrashMessage(
    String context, String deviceId, Object e, StackTrace stackTrace) {
  debugPrint('Error in $context for device $deviceId: $e\n$stackTrace');
}
