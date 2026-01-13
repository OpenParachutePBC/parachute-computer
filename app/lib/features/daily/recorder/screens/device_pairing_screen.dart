import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/recorder/models/omi_device.dart';
import 'package:parachute/features/daily/recorder/providers/omi_providers.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';
import 'package:parachute/features/daily/recorder/utils/platform_utils.dart';

/// Screen for scanning and pairing with Omi devices
class DevicePairingScreen extends ConsumerStatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  ConsumerState<DevicePairingScreen> createState() =>
      _DevicePairingScreenState();
}

class _DevicePairingScreenState extends ConsumerState<DevicePairingScreen> {
  bool _isScanning = false;
  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Auto-start scan when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScan();
    });
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      final bluetoothService = ref.read(omiBluetoothServiceProvider);

      await bluetoothService.scanForDevices(
        timeoutSeconds: 10,
        onDevicesFound: (devices) {
          // Update discovered devices list
          ref.read(discoveredOmiDevicesProvider.notifier).state = devices;
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Scan failed: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _connectToDevice(OmiDevice device) async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final bluetoothService = ref.read(omiBluetoothServiceProvider);
      final captureService = ref.read(omiCaptureServiceProvider);

      // Connect to device
      await bluetoothService.connectToDevice(
        device.id,
        onConnectionStateChanged: (deviceId, state) {
          debugPrint('[DevicePairingScreen] Connection state: $state');
        },
      );

      // Save as paired device
      await savePairedDevice(device);

      // Note: The callback for recording saves is set up in omiCaptureServiceProvider
      // to avoid widget disposal issues. No need to set it up here.

      // Start listening for button events
      await captureService.startListening();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${device.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection failed: $e';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  Future<void> _disconnectDevice() async {
    final bluetoothService = ref.read(omiBluetoothServiceProvider);
    final captureService = ref.read(omiCaptureServiceProvider);

    await captureService.stopListening();
    await bluetoothService.disconnect();
    await clearPairedDevice();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Device disconnected')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check platform support
    if (!PlatformUtils.shouldShowOmiFeatures) {
      return Scaffold(
        appBar: AppBar(title: const Text('Omi Device')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.bluetooth_disabled,
                  size: 64,
                  color: Colors.grey,
                ),
                const SizedBox(height: 16),
                Text(
                  PlatformUtils.getBluetoothUnsupportedMessage(),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final discoveredDevices = ref.watch(discoveredOmiDevicesProvider);
    final connectedDeviceAsync = ref.watch(connectedOmiDeviceProvider);
    final connectionStateAsync = ref.watch(omiConnectionStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Omi Device'),
        actions: [
          if (_isScanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScan,
              tooltip: 'Scan for devices',
            ),
        ],
      ),
      body: Column(
        children: [
          // Error message
          if (_errorMessage != null)
            Container(
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(() => _errorMessage = null),
                  ),
                ],
              ),
            ),

          // Connected device card
          if (connectedDeviceAsync.hasValue &&
              connectedDeviceAsync.value != null)
            _buildConnectedDeviceCard(
              connectedDeviceAsync.value!,
              connectionStateAsync.valueOrNull,
            ),

          // Device list
          Expanded(
            child: _buildDeviceList(
              discoveredDevices,
              connectedDeviceAsync.valueOrNull,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedDeviceCard(
    OmiDevice device,
    DeviceConnectionState? state,
  ) {
    final isConnected = state == DeviceConnectionState.connected;
    final batteryLevelAsync = ref.watch(omiBatteryLevelProvider);
    final batteryLevel = batteryLevelAsync.valueOrNull ?? -1;

    return Card(
      margin: const EdgeInsets.all(16),
      color: isConnected ? Colors.green.shade50 : Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isConnected ? 'Connected' : 'Connecting...',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: isConnected ? Colors.green : Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (isConnected && batteryLevel >= 0) ...[
                  Icon(
                    _getBatteryIcon(batteryLevel),
                    color: _getBatteryColor(batteryLevel),
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$batteryLevel%',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _getBatteryColor(batteryLevel),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(device.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'ID: ${device.getShortId()}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (device.modelNumber != null) ...[
              const SizedBox(height: 4),
              Text('Model: ${device.modelNumber}'),
            ],
            if (device.firmwareRevision != null) ...[
              const SizedBox(height: 4),
              Text('Firmware: ${device.firmwareRevision}'),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _disconnectDevice,
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Disconnect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getBatteryIcon(int level) {
    if (level > 90) return Icons.battery_full;
    if (level > 60) return Icons.battery_5_bar;
    if (level > 40) return Icons.battery_4_bar;
    if (level > 20) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  Color _getBatteryColor(int level) {
    if (level > 20) return Colors.green;
    if (level > 10) return Colors.orange;
    return Colors.red;
  }

  Widget _buildDeviceList(List<OmiDevice> devices, OmiDevice? connectedDevice) {
    if (_isScanning && devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Scanning for Omi devices...'),
          ],
        ),
      );
    }

    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No devices found'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan Again'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        final isConnected = connectedDevice?.id == device.id;

        return ListTile(
          leading: Icon(
            isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
            color: isConnected ? Colors.green : null,
          ),
          title: Text(device.name),
          subtitle: Text('Signal: ${device.rssi} dBm'),
          trailing: isConnected
              ? const Icon(Icons.check_circle, color: Colors.green)
              : _isConnecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : ElevatedButton(
                  onPressed: () => _connectToDevice(device),
                  child: const Text('Connect'),
                ),
          onTap: isConnected ? null : () => _connectToDevice(device),
        );
      },
    );
  }
}
