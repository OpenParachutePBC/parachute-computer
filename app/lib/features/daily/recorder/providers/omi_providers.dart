import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import 'package:parachute/features/daily/recorder/models/omi_device.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_bluetooth_service.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_capture_service.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_firmware_service.dart';
import 'package:parachute/features/daily/recorder/providers/service_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provider for OmiBluetoothService
///
/// This service manages BLE scanning, device discovery, and connections.
/// Auto-reconnects to the last paired device on startup if one exists.
/// The feature flag controls UI visibility, not auto-reconnect behavior.
final omiBluetoothServiceProvider = Provider<OmiBluetoothService>((ref) {
  final service = OmiBluetoothService();

  // Check if we should start the service:
  // 1. If Omi feature flag is enabled, OR
  // 2. If we have a previously paired device (user used Omi before)
  _shouldStartService().then((shouldStart) async {
    if (shouldStart) {
      service.start();
      await _attemptAutoReconnect(ref, service);
    }
  }).catchError((e) {
    debugPrint('[OmiBluetoothService] Error initializing: $e');
  });

  ref.onDispose(() {
    service.stop().catchError((e) {
      debugPrint('[OmiBluetoothService] Error stopping: $e');
    });
  });

  return service;
});

/// Check if we should start the Bluetooth service
Future<bool> _shouldStartService() async {
  final prefs = await SharedPreferences.getInstance();

  // Start if we have a previously paired device
  final deviceId = prefs.getString('omi_last_paired_device_id');
  if (deviceId != null && deviceId.isNotEmpty) {
    return true;
  }

  // Or if feature flag is enabled (for first-time setup)
  final featureEnabled = prefs.getBool('feature_omi_enabled') ?? false;
  return featureEnabled;
}

/// Attempt to auto-reconnect to the last paired Omi device
Future<void> _attemptAutoReconnect(ProviderRef<OmiBluetoothService> ref, OmiBluetoothService service) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final autoReconnectEnabled = prefs.getBool('omi_auto_reconnect_enabled') ?? true;
    if (!autoReconnectEnabled) return;

    final deviceId = prefs.getString('omi_last_paired_device_id');
    if (deviceId == null || deviceId.isEmpty) return;

    // Small delay to let Bluetooth initialize
    await Future.delayed(const Duration(milliseconds: 500));

    // Attempt reconnection - capture service will be started by omiCaptureServiceProvider
    // when it observes the connection state change
    await service.reconnectToDevice(
      deviceId,
      onConnectionStateChanged: (id, state) {},
    );
  } catch (e) {
    debugPrint('[OmiBluetoothService] Auto-reconnect error: $e');
  }
}

/// Provider for the current connection state
///
/// Returns the connection state of the active Omi device connection.
/// This is a StreamProvider that reactively updates when connection state changes.
final omiConnectionStateProvider = StreamProvider<DeviceConnectionState?>((
  ref,
) {
  final bluetoothService = ref.watch(omiBluetoothServiceProvider);
  return bluetoothService.connectionStateStream;
});

/// Provider for the battery level of the connected Omi device
///
/// Returns the battery percentage (0-100) or -1 if unknown.
/// This is a StreamProvider that reactively updates when battery level changes.
final omiBatteryLevelProvider = StreamProvider<int>((ref) {
  final bluetoothService = ref.watch(omiBluetoothServiceProvider);
  return bluetoothService.batteryLevelStream;
});

/// Provider for the currently connected Omi device
///
/// Returns null if no device is connected.
/// This is a StreamProvider that reactively updates when connection state changes.
final connectedOmiDeviceProvider = StreamProvider<OmiDevice?>((ref) {
  final bluetoothService = ref.watch(omiBluetoothServiceProvider);

  // Start with current connection state, then listen to stream
  return bluetoothService.connectedDeviceStream;
});

/// Provider for OmiCaptureService
///
/// This service handles audio recording from the Omi device.
/// It depends on OmiBluetoothService, JournalService, and TranscriptionServiceAdapter.
///
/// This provider automatically sets up a callback to trigger journal refresh
/// when new recordings are saved from the Omi device.
final omiCaptureServiceProvider = Provider<OmiCaptureService>((ref) {
  final bluetoothService = ref.watch(omiBluetoothServiceProvider);
  final transcriptionService = ref.watch(transcriptionServiceAdapterProvider);

  final service = OmiCaptureService(
    bluetoothService: bluetoothService,
    getJournalService: () => ref.read(journalServiceFutureProvider.future),
    transcriptionService: transcriptionService,
  );

  // Set up callback to trigger journal refresh when new recordings are saved
  service.onRecordingSaved = (entry) {
    ref.invalidate(todayJournalProvider);
    ref.invalidate(selectedJournalProvider);
  };

  // Listen for connection state changes and auto-start listening when connected
  StreamSubscription<OmiDevice?>? connectionSubscription;
  connectionSubscription = bluetoothService.connectedDeviceStream.listen((device) {
    if (device != null) {
      service.startListening();
    }
  });

  // Also start listening if already connected when provider is created
  if (bluetoothService.isConnected) {
    service.startListening();
  }

  ref.onDispose(() {
    connectionSubscription?.cancel();
    service.dispose().catchError((e) {
      debugPrint('[OmiCaptureService] Error disposing: $e');
    });
  });

  return service;
});

/// Provider for OmiFirmwareService
///
/// This service handles OTA firmware updates for Omi devices.
/// Uses ChangeNotifierProvider to enable reactive UI updates during firmware updates.
final omiFirmwareServiceProvider = ChangeNotifierProvider<OmiFirmwareService>((
  ref,
) {
  return OmiFirmwareService();
});

/// Provider for discovered devices during scan
///
/// This is a StateProvider that gets updated during device scanning.
final discoveredOmiDevicesProvider = StateProvider<List<OmiDevice>>((ref) {
  return [];
});

/// Provider for the last paired device ID
///
/// Persists to SharedPreferences for auto-reconnect functionality.
final lastPairedDeviceIdProvider = FutureProvider<String?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('omi_last_paired_device_id');
});

/// Provider for the last paired device info
///
/// Returns the full OmiDevice object from SharedPreferences.
final lastPairedDeviceProvider = FutureProvider<OmiDevice?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final deviceJson = prefs.getString('omi_last_paired_device_json');

  if (deviceJson == null || deviceJson.isEmpty) {
    return null;
  }

  try {
    final json = jsonDecode(deviceJson) as Map<String, dynamic>;
    return OmiDevice.fromJson(json);
  } catch (e) {
    return null;
  }
});

/// Helper function to save paired device to SharedPreferences
Future<void> savePairedDevice(OmiDevice device) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('omi_last_paired_device_id', device.id);
  await prefs.setString(
    'omi_last_paired_device_json',
    jsonEncode(device.toJson()),
  );
}

/// Helper function to clear paired device from SharedPreferences
Future<void> clearPairedDevice() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('omi_last_paired_device_id');
  await prefs.remove('omi_last_paired_device_json');
}

/// Provider for auto-reconnect preference
final autoReconnectEnabledProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('omi_auto_reconnect_enabled') ?? true; // Default to true
});

/// Helper function to save auto-reconnect preference
Future<void> setAutoReconnectEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('omi_auto_reconnect_enabled', enabled);
}
