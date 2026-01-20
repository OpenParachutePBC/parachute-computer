import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:parachute/features/daily/recorder/services/omi/device_connection.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';

/// Omi-specific device connection implementation
///
/// Handles audio streaming, button events, battery monitoring, and codec detection
/// for Omi wearable devices.
class OmiDeviceConnection extends DeviceConnection {
  BluetoothService? _batteryService;
  BluetoothService? _omiService;
  BluetoothService? _buttonService;
  BluetoothService? _deviceInfoService;
  BluetoothService? _storageService;

  OmiDeviceConnection({required super.device, required super.bleDevice});

  String get deviceId => device.id;

  @override
  Future<void> connect({
    Function(String deviceId, DeviceConnectionState state)?
    onConnectionStateChanged,
  }) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);

    // Discover required services
    _omiService = await getService(omiServiceUuid);
    if (_omiService == null) {
      debugPrint('[OmiConnection] Omi service not found');
      throw DeviceConnectionException('Omi BLE service not found');
    }

    _batteryService = await getService(batteryServiceUuid);
    _buttonService = await getService(buttonServiceUuid);
    _deviceInfoService = await getService(deviceInformationServiceUuid);
    _storageService = await getService(storageDataStreamServiceUuid);

    // Read firmware version (for device info)
    await getFirmwareVersion();
  }

  @override
  Future<bool> isConnected() async {
    return bleDevice.isConnected;
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    if (_batteryService == null) return -1;

    final characteristic = getCharacteristic(
      _batteryService!,
      batteryLevelCharacteristicUuid,
    );
    if (characteristic == null) return -1;

    try {
      final value = await characteristic.read();
      if (value.isNotEmpty) {
        return value[0];
      }
    } catch (e) {
      debugPrint('[OmiConnection] Error reading battery: $e');
    }

    return -1;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    if (_batteryService == null) return null;

    final characteristic = getCharacteristic(
      _batteryService!,
      batteryLevelCharacteristicUuid,
    );
    if (characteristic == null) return null;

    try {
      // Read current value
      final currentValue = await characteristic.read();
      if (currentValue.isNotEmpty && onBatteryLevelChange != null) {
        onBatteryLevelChange(currentValue[0]);
      }

      // Subscribe to notifications
      await characteristic.setNotifyValue(true);

      final listener = characteristic.lastValueStream.listen((value) {
        if (value.isNotEmpty && onBatteryLevelChange != null) {
          onBatteryLevelChange(value[0]);
        }
      });

      bleDevice.cancelWhenDisconnected(listener);
      return listener;
    } catch (e) {
      debugPrint('[OmiConnection] Error subscribing to battery: $e');
    }

    return null;
  }

  @override
  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    if (_buttonService == null) return null;

    final characteristic = getCharacteristic(
      _buttonService!,
      buttonTriggerCharacteristicUuid,
    );
    if (characteristic == null) return null;

    // Verify characteristic supports notifications
    if (!characteristic.properties.notify &&
        !characteristic.properties.indicate) {
      return null;
    }

    try {
      if (!bleDevice.isConnected) return null;

      await characteristic.setNotifyValue(true);

      // Subscribe to button events
      final listener = characteristic.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          onButtonReceived(value);
        }
      });

      bleDevice.cancelWhenDisconnected(listener);
      return listener;
    } catch (e) {
      debugPrint('[OmiConnection] Error subscribing to button: $e');
    }

    return null;
  }

  @override
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    if (_omiService == null) return null;

    final characteristic = getCharacteristic(
      _omiService!,
      audioDataStreamCharacteristicUuid,
    );
    if (characteristic == null) return null;

    // Verify characteristic supports notifications
    if (!characteristic.properties.notify) return null;

    try {
      if (!bleDevice.isConnected) return null;

      // Request larger MTU on Android for better audio throughput
      if (Platform.isAndroid && bleDevice.mtuNow < 512) {
        try {
          await bleDevice.requestMtu(512);
        } catch (_) {}
      }

      await characteristic.setNotifyValue(true);

      // Subscribe to audio stream
      final listener = characteristic.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          onAudioBytesReceived(value);
        }
      });

      bleDevice.cancelWhenDisconnected(listener);
      return listener;
    } catch (e) {
      debugPrint('[OmiConnection] Error subscribing to audio: $e');
    }

    return null;
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    if (_omiService == null) return BleAudioCodec.unknown;

    final characteristic = getCharacteristic(
      _omiService!,
      audioCodecCharacteristicUuid,
    );
    if (characteristic == null) return BleAudioCodec.unknown;

    try {
      final value = await characteristic.read();
      if (value.isNotEmpty) {
        return _parseCodecId(value[0]);
      }
    } catch (e) {
      debugPrint('[OmiConnection] Error reading codec: $e');
    }

    return BleAudioCodec.unknown;
  }

  /// Read firmware version from device
  Future<String?> getFirmwareVersion() async {
    if (_deviceInfoService == null) return null;

    final characteristic = getCharacteristic(
      _deviceInfoService!,
      firmwareRevisionCharacteristicUuid,
    );
    if (characteristic == null) return null;

    try {
      final value = await characteristic.read();
      if (value.isNotEmpty) {
        return String.fromCharCodes(value);
      }
    } catch (e) {
      debugPrint('[OmiConnection] Error reading firmware version: $e');
    }

    return null;
  }

  /// Parse codec ID from device to BleAudioCodec enum
  BleAudioCodec _parseCodecId(int codecId) {
    switch (codecId) {
      case 1:
        return BleAudioCodec.pcm8;
      case 10:
        return BleAudioCodec.pcm16;
      case 20:
        return BleAudioCodec.opus;
      case 11:
        return BleAudioCodec.mulaw8;
      case 12:
        return BleAudioCodec.mulaw16;
      default:
        return BleAudioCodec.unknown;
    }
  }

  // ============================================================
  // Storage Service Methods (Store-and-Forward)
  // ============================================================

  /// Check if storage service is available
  bool get hasStorageService => _storageService != null;

  /// Get storage info from device
  /// Returns [fileSize, currentOffset] or null if unavailable
  Future<List<int>?> getStorageInfo() async {
    if (_storageService == null) return null;

    final characteristic = getCharacteristic(
      _storageService!,
      storageReadControlCharacteristicUuid,
    );
    if (characteristic == null) return null;

    try {
      final value = await characteristic.read();
      if (value.length >= 8) {
        // Two 32-bit integers: file_size and offset
        final fileSize = value[0] | (value[1] << 8) | (value[2] << 16) | (value[3] << 24);
        final offset = value[4] | (value[5] << 8) | (value[6] << 16) | (value[7] << 24);
        return [fileSize, offset];
      }
    } catch (e) {
      debugPrint('[OmiConnection] Error reading storage info: $e');
    }

    return null;
  }

  /// Send a command to the storage service
  /// Commands: 0=READ, 1=DELETE, 2=NUKE, 3=STOP, 50=HEARTBEAT
  Future<bool> sendStorageCommand(int command, int fileNum, [int? size]) async {
    if (_storageService == null) return false;

    final characteristic = getCharacteristic(
      _storageService!,
      storageDataStreamCharacteristicUuid,
    );
    if (characteristic == null) return false;

    try {
      List<int> data;
      if (size != null) {
        // 6-byte command with size
        data = [
          command,
          fileNum,
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ];
      } else {
        // 2-byte command
        data = [command, fileNum];
      }

      await characteristic.write(data, withoutResponse: false);
      return true;
    } catch (e) {
      debugPrint('[OmiConnection] Error sending storage command: $e');
    }

    return false;
  }

  /// Start downloading a recording from device storage
  /// Returns a stream subscription that receives audio data chunks
  Future<StreamSubscription?> startStorageDownload({
    required int fileNum,
    required int startOffset,
    required void Function(List<int> data) onDataReceived,
    required void Function() onComplete,
    required void Function(String error) onError,
  }) async {
    if (_storageService == null) {
      onError('Storage service not available');
      return null;
    }

    final writeCharacteristic = getCharacteristic(
      _storageService!,
      storageDataStreamCharacteristicUuid,
    );

    if (writeCharacteristic == null) {
      onError('Storage write characteristic not found');
      return null;
    }

    try {
      // Subscribe to notifications for data stream
      await writeCharacteristic.setNotifyValue(true);

      // Use onValueReceived for fresh notifications only (not cached lastValue)
      final listener = writeCharacteristic.onValueReceived.listen((value) {
        if (value.isEmpty) return;

        // Check for completion/error signals
        if (value.length == 1) {
          final code = value[0];
          if (code == 0) {
            onComplete();
          } else {
            onError('Storage error code: $code');
          }
          return;
        }

        onDataReceived(value);
      });

      bleDevice.cancelWhenDisconnected(listener);

      // Send read command to start transfer
      final success = await sendStorageCommand(0, fileNum, startOffset);
      if (!success) {
        await listener.cancel();
        onError('Failed to send read command');
        return null;
      }

      return listener;
    } catch (e) {
      debugPrint('[OmiConnection] Error starting storage download: $e');
      onError('Error starting download: $e');
    }

    return null;
  }

  /// Delete a file from device storage
  Future<bool> deleteStorageFile(int fileNum) async {
    return await sendStorageCommand(1, fileNum);
  }

  /// Delete all files from device storage
  Future<bool> nukeStorage() async {
    return await sendStorageCommand(2, 1);
  }

  /// Stop ongoing storage transfer
  Future<bool> stopStorageTransfer() async {
    return await sendStorageCommand(3, 1);
  }

  /// Send heartbeat to keep storage connection alive
  Future<bool> sendStorageHeartbeat() async {
    return await sendStorageCommand(50, 1);
  }
}
