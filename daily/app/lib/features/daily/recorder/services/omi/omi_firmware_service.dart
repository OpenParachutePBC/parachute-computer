import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:parachute/features/daily/recorder/models/omi_device.dart';
import 'package:path_provider/path_provider.dart';

/// Service for managing OTA firmware updates for Omi devices
///
/// Supports Nordic DFU protocol for updating nRF52840-based devices.
/// This class extends ChangeNotifier to enable reactive UI updates during firmware updates.
class OmiFirmwareService extends ChangeNotifier {
  static const String _latestFirmwareAssetPath =
      'assets/firmware/devkit-v2-firmware-latest.zip';
  static const String _expectedFirmwareVersion =
      '2.0.12'; // Update this when new firmware is released

  bool _isUpdating = false;
  int _updateProgress = 0;
  String? _updateError;
  String _updateStatus = 'Idle';

  bool get isUpdating => _isUpdating;
  int get updateProgress => _updateProgress;
  String? get updateError => _updateError;
  String get updateStatus => _updateStatus;

  /// Check if firmware update is available
  ///
  /// Compares device firmware version against bundled firmware version
  Future<bool> isUpdateAvailable(OmiDevice device) async {
    if (device.firmwareRevision == null) {
      debugPrint('[OmiFirmwareService] Device firmware version unknown');
      return false;
    }

    // Check if firmware asset exists
    final assetExists = await _checkFirmwareAssetExists();
    if (!assetExists) {
      debugPrint('[OmiFirmwareService] No firmware asset found');
      return false;
    }

    // Simple version comparison (assumes semantic versioning)
    final deviceVersion = device.firmwareRevision!;
    final isOlder =
        _compareVersions(deviceVersion, _expectedFirmwareVersion) < 0;

    debugPrint(
      '[OmiFirmwareService] Device version: $deviceVersion, Latest: $_expectedFirmwareVersion, Update available: $isOlder',
    );
    return isOlder;
  }

  /// Get the latest firmware version available
  String getLatestFirmwareVersion() {
    return _expectedFirmwareVersion;
  }

  /// Start OTA firmware update
  ///
  /// Uses Nordic DFU protocol to flash firmware over BLE.
  /// Requires device to be connected.
  Future<void> startFirmwareUpdate({
    required OmiDevice device,
    required Function(int progress) onProgress,
    required Function() onComplete,
    required Function(String error) onError,
  }) async {
    if (_isUpdating) {
      debugPrint('[OmiFirmwareService] Update already in progress');
      return;
    }

    _isUpdating = true;
    _updateProgress = 0;
    _updateError = null;
    _updateStatus = 'Preparing firmware...';
    notifyListeners();

    try {
      // Copy firmware from assets to temporary file (required by Nordic DFU)
      final firmwareFile = await _copyFirmwareToTemp();

      debugPrint(
        '[OmiFirmwareService] Starting DFU update for device ${device.id}',
      );
      debugPrint('[OmiFirmwareService] Firmware file: $firmwareFile');

      _updateStatus = 'Initiating DFU mode...';
      notifyListeners();

      // Give device time to prepare for DFU
      await Future.delayed(const Duration(seconds: 2));

      final dfu = NordicDfu();
      await dfu.startDfu(
        device.id,
        firmwareFile,
        fileInAsset: false, // We've already copied to temp file
        numberOfPackets: 8,
        enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
        iosSpecialParameter: const IosSpecialParameter(
          packetReceiptNotificationParameter: 8,
          forceScanningForNewAddressInLegacyDfu: true,
          connectionTimeout: 60,
        ),
        androidSpecialParameter: const AndroidSpecialParameter(
          packetReceiptNotificationsEnabled: true,
          rebootTime: 1000,
        ),
        onProgressChanged:
            (deviceAddress, percent, speed, avgSpeed, currentPart, partsTotal) {
              debugPrint('[OmiFirmwareService] Progress: $percent%');
              _updateProgress = percent.toInt();
              _updateStatus = 'Uploading firmware... $percent%';
              notifyListeners();
              onProgress(percent.toInt());
            },
        onError: (deviceAddress, error, errorType, message) {
          final errorMsg = 'DFU Error: $error ($errorType) - $message';
          debugPrint('[OmiFirmwareService] $errorMsg');
          _updateError = errorMsg;
          _updateStatus = 'Update failed';
          _isUpdating = false;
          notifyListeners();
          onError(errorMsg);
        },
        onDeviceConnecting: (deviceAddress) {
          debugPrint('[OmiFirmwareService] Device connecting: $deviceAddress');
          _updateStatus = 'Connecting to device...';
          notifyListeners();
        },
        onDeviceConnected: (deviceAddress) {
          debugPrint('[OmiFirmwareService] Device connected: $deviceAddress');
          _updateStatus = 'Connected in DFU mode';
          notifyListeners();
        },
        onDfuProcessStarting: (deviceAddress) {
          debugPrint('[OmiFirmwareService] DFU process starting');
          _updateStatus = 'Starting DFU process...';
          notifyListeners();
        },
        onDfuProcessStarted: (deviceAddress) {
          debugPrint('[OmiFirmwareService] DFU process started');
          _updateStatus = 'DFU process started';
          notifyListeners();
        },
        onEnablingDfuMode: (deviceAddress) {
          debugPrint('[OmiFirmwareService] Enabling DFU mode');
          _updateStatus = 'Entering bootloader mode...';
          notifyListeners();
        },
        onFirmwareValidating: (deviceAddress) {
          debugPrint('[OmiFirmwareService] Validating firmware');
          _updateStatus = 'Validating firmware...';
          notifyListeners();
        },
        onDfuCompleted: (deviceAddress) {
          debugPrint('[OmiFirmwareService] DFU completed successfully!');
          _isUpdating = false;
          _updateProgress = 100;
          _updateStatus = 'Update completed! Device rebooting...';
          notifyListeners();
          onComplete();
        },
      );
    } catch (e) {
      final errorMsg = 'Failed to start firmware update: $e';
      debugPrint('[OmiFirmwareService] $errorMsg');
      _updateError = errorMsg;
      _updateStatus = 'Failed to start update';
      _isUpdating = false;
      notifyListeners();
      onError(errorMsg);
    }
  }

  /// Check if firmware asset exists in bundle
  Future<bool> _checkFirmwareAssetExists() async {
    try {
      await rootBundle.load(_latestFirmwareAssetPath);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Copy firmware from assets to temporary file
  Future<String> _copyFirmwareToTemp() async {
    final ByteData data = await rootBundle.load(_latestFirmwareAssetPath);
    final Directory tempDir = await getTemporaryDirectory();
    final String firmwareFile = '${tempDir.path}/omi_firmware_update.zip';

    final File tempFile = File(firmwareFile);
    await tempFile.writeAsBytes(data.buffer.asUint8List());

    debugPrint('[OmiFirmwareService] Firmware copied to: $firmwareFile');
    debugPrint(
      '[OmiFirmwareService] File size: ${await tempFile.length()} bytes',
    );

    return firmwareFile;
  }

  /// Compare semantic versions (e.g., "2.0.12" vs "2.0.11")
  ///
  /// Returns:
  /// - negative if v1 < v2
  /// - 0 if v1 == v2
  /// - positive if v1 > v2
  int _compareVersions(String v1, String v2) {
    final parts1 = v1.split('.').map(int.tryParse).toList();
    final parts2 = v2.split('.').map(int.tryParse).toList();

    for (int i = 0; i < parts1.length && i < parts2.length; i++) {
      final p1 = parts1[i] ?? 0;
      final p2 = parts2[i] ?? 0;

      if (p1 != p2) {
        return p1.compareTo(p2);
      }
    }

    return parts1.length.compareTo(parts2.length);
  }

  /// Reset error state
  void clearError() {
    _updateError = null;
    notifyListeners();
  }
}
