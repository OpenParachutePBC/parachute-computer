import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:parachute/features/daily/recorder/models/omi_device.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';

/// Exception thrown when device connection fails
class DeviceConnectionException implements Exception {
  final String message;
  DeviceConnectionException(this.message);

  @override
  String toString() => 'DeviceConnectionException: $message';
}

/// Base class for BLE device connections
///
/// Handles common BLE operations like connecting, disconnecting, service discovery,
/// and characteristic access. Subclasses implement device-specific functionality.
abstract class DeviceConnection {
  final OmiDevice device;
  final BluetoothDevice bleDevice;

  DateTime? lastActivityAt = DateTime.now();
  DeviceConnectionState status = DeviceConnectionState.disconnected;
  DateTime? pongAt; // Last successful ping time

  List<BluetoothService> _services = [];

  DeviceConnectionState get connectionState => status;

  Function(String deviceId, DeviceConnectionState state)?
      _connectionStateChangedCallback;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  DeviceConnection({
    required this.device,
    required this.bleDevice,
  });

  /// Connect to the device and discover services
  Future<void> connect({
    Function(String deviceId, DeviceConnectionState state)?
        onConnectionStateChanged,
  }) async {
    if (status == DeviceConnectionState.connected) {
      throw DeviceConnectionException(
        'Already connected. Disconnect before starting new connection.',
      );
    }

    debugPrint(
        '[DeviceConnection] Connecting to ${device.name} (${device.id})');

    _connectionStateChangedCallback = onConnectionStateChanged;

    // Listen to connection state changes
    _connectionStateSubscription = bleDevice.connectionState.listen(
      (BluetoothConnectionState state) async {
        await _onBleConnectionStateChanged(state);
      },
    );

    try {
      // Wait for Bluetooth adapter to be on
      await FlutterBluePlus.adapterState
          .where((val) => val == BluetoothAdapterState.on)
          .first;

      // Connect to device
      await bleDevice.connect();

      // Wait for connection to be established
      await bleDevice.connectionState
          .where((val) => val == BluetoothConnectionState.connected)
          .first;

      debugPrint('[DeviceConnection] Connected successfully');
    } on FlutterBluePlusException catch (e) {
      throw DeviceConnectionException(
          'Flutter Blue Plus error: ${e.toString()}');
    }

    // Request larger MTU on Android for better throughput
    if (Platform.isAndroid && bleDevice.mtuNow < 512) {
      try {
        await bleDevice.requestMtu(512);
        debugPrint('[DeviceConnection] MTU set to 512');
      } catch (e) {
        debugPrint('[DeviceConnection] MTU request failed: $e');
      }
    }

    // Verify connection with ping
    final pingSuccess = await ping();
    if (!pingSuccess) {
      throw DeviceConnectionException('Connection verification (ping) failed');
    }

    // Discover services
    debugPrint('[DeviceConnection] Discovering services...');
    _services = await bleDevice.discoverServices();
    debugPrint('[DeviceConnection] Discovered ${_services.length} services');

    status = DeviceConnectionState.connected;
    _notifyConnectionStateChanged();
  }

  /// Handle BLE connection state changes
  Future<void> _onBleConnectionStateChanged(
      BluetoothConnectionState state) async {
    debugPrint('[DeviceConnection] BLE state changed: $state');

    if (state == BluetoothConnectionState.disconnected &&
        status == DeviceConnectionState.connected) {
      debugPrint('[DeviceConnection] Device disconnected unexpectedly');
      status = DeviceConnectionState.disconnected;
      await disconnect();
      return;
    }

    if (state == BluetoothConnectionState.connected &&
        status == DeviceConnectionState.disconnected) {
      status = DeviceConnectionState.connected;
      _notifyConnectionStateChanged();
    }
  }

  /// Notify listeners of connection state change
  void _notifyConnectionStateChanged() {
    _connectionStateChangedCallback?.call(device.id, status);
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    debugPrint('[DeviceConnection] Disconnecting from ${device.name}');

    status = DeviceConnectionState.disconnected;
    _notifyConnectionStateChanged();

    _connectionStateChangedCallback = null;

    try {
      await bleDevice.disconnect();
    } catch (e) {
      debugPrint('[DeviceConnection] Error during disconnect: $e');
    }

    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    _services.clear();

    debugPrint('[DeviceConnection] Disconnected');
  }

  /// Ping device to verify connection is alive
  Future<bool> ping() async {
    try {
      final rssi = await bleDevice.readRssi();
      debugPrint('[DeviceConnection] Ping successful, RSSI: $rssi');
      pongAt = DateTime.now();
      lastActivityAt = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('[DeviceConnection] Ping failed: $e');
      return false;
    }
  }

  /// Check if device is currently connected
  Future<bool> isConnected() async {
    try {
      final state = await bleDevice.connectionState.first;
      return state == BluetoothConnectionState.connected;
    } catch (e) {
      return false;
    }
  }

  /// Get a BLE service by UUID
  Future<BluetoothService?> getService(String uuid) async {
    return _services.firstWhereOrNull(
      (service) => service.uuid.str128.toLowerCase() == uuid.toLowerCase(),
    );
  }

  /// Get a characteristic from a service by UUID
  BluetoothCharacteristic? getCharacteristic(
    BluetoothService service,
    String uuid,
  ) {
    return service.characteristics.firstWhereOrNull(
      (characteristic) =>
          characteristic.uuid.str128.toLowerCase() == uuid.toLowerCase(),
    );
  }

  // Abstract methods to be implemented by subclasses

  /// Retrieve battery level (0-100)
  Future<int> performRetrieveBatteryLevel();

  /// Listen to battery level changes
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  });

  /// Listen to audio bytes from device
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  });

  /// Listen to button events from device
  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  });

  /// Get audio codec being used by device
  Future<BleAudioCodec> performGetAudioCodec();

  // Public wrapper methods that check connection

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) {
      return await performRetrieveBatteryLevel();
    }
    return -1;
  }

  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    if (await isConnected()) {
      return await performGetBleBatteryLevelListener(
        onBatteryLevelChange: onBatteryLevelChange,
      );
    }
    return null;
  }

  Future<StreamSubscription?> getBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleAudioBytesListener(
        onAudioBytesReceived: onAudioBytesReceived,
      );
    }
    return null;
  }

  Future<StreamSubscription?> getBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleButtonListener(
        onButtonReceived: onButtonReceived,
      );
    }
    return null;
  }

  Future<BleAudioCodec> getAudioCodec() async {
    if (await isConnected()) {
      return await performGetAudioCodec();
    }
    return BleAudioCodec.pcm8; // Default fallback
  }
}
