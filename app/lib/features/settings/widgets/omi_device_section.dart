import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/daily/recorder/providers/omi_providers.dart';
import 'package:parachute/features/daily/recorder/screens/device_pairing_screen.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_connection.dart';

/// Omi Device settings section (pairing and firmware updates)
class OmiDeviceSection extends ConsumerWidget {
  const OmiDeviceSection({super.key});

  IconData _getBatteryIcon(int level) {
    if (level > 90) return Icons.battery_full;
    if (level > 60) return Icons.battery_5_bar;
    if (level > 40) return Icons.battery_4_bar;
    if (level > 20) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }

  Color _getBatteryColor(int level) {
    if (level > 20) return BrandColors.success;
    if (level > 10) return BrandColors.warning;
    return BrandColors.error;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedDeviceAsync = ref.watch(connectedOmiDeviceProvider);
    final connectedDevice = connectedDeviceAsync.value;
    final firmwareService = ref.watch(omiFirmwareServiceProvider);
    final isConnected = connectedDevice != null;
    final batteryLevelAsync = ref.watch(omiBatteryLevelProvider);
    final batteryLevel = batteryLevelAsync.valueOrNull ?? -1;
    final isFirmwareUpdating = firmwareService.isUpdating;
    final displayConnected = isConnected || isFirmwareUpdating;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.watch,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Omi Device',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Connect your Omi wearable for hands-free voice journaling',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Device Status Card
        _buildOmiDeviceCard(
          context,
          ref,
          connectedDevice,
          isConnected,
          displayConnected,
          batteryLevel,
          isFirmwareUpdating,
          firmwareService,
          isDark,
        ),

        // Firmware Update Card (only when connected)
        if (isConnected) ...[
          SizedBox(height: Spacing.lg),
          _buildFirmwareUpdateCard(
            context,
            ref,
            connectedDevice,
            isConnected,
            firmwareService,
            isDark,
          ),
        ],
      ],
    );
  }

  Widget _buildOmiDeviceCard(
    BuildContext context,
    WidgetRef ref,
    dynamic connectedDevice,
    bool isConnected,
    bool displayConnected,
    int batteryLevel,
    bool isFirmwareUpdating,
    dynamic firmwareService,
    bool isDark,
  ) {
    final statusColor = displayConnected
        ? (isFirmwareUpdating ? BrandColors.turquoise : BrandColors.success)
        : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood);

    return InkWell(
      onTap: isFirmwareUpdating
          ? null
          : () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const DevicePairingScreen(),
                ),
              );
            },
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: statusColor, width: 2),
        ),
        child: Row(
          children: [
            Icon(
              isFirmwareUpdating
                  ? Icons.system_update_alt
                  : (isConnected ? Icons.bluetooth_connected : Icons.bluetooth),
              color: statusColor,
              size: 32,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isFirmwareUpdating
                        ? 'Updating Firmware'
                        : (isConnected ? 'Connected' : 'Not Connected'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    isFirmwareUpdating
                        ? firmwareService.updateStatus
                        : (isConnected
                            ? connectedDevice.name
                            : 'Tap to pair your device'),
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                  ),
                  if (isConnected &&
                      connectedDevice.firmwareRevision != null) ...[
                    SizedBox(height: Spacing.xs),
                    Text(
                      'Firmware: ${connectedDevice.firmwareRevision}',
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                  ],
                  if (isConnected && batteryLevel >= 0) ...[
                    SizedBox(height: Spacing.xs),
                    Row(
                      children: [
                        Icon(
                          _getBatteryIcon(batteryLevel),
                          size: 14,
                          color: _getBatteryColor(batteryLevel),
                        ),
                        SizedBox(width: Spacing.xs),
                        Text(
                          'Battery: $batteryLevel%',
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: _getBatteryColor(batteryLevel),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFirmwareUpdateCard(
    BuildContext context,
    WidgetRef ref,
    dynamic connectedDevice,
    bool isConnected,
    dynamic firmwareService,
    bool isDark,
  ) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: BrandColors.turquoise.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: BrandColors.turquoise.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update,
                  color: BrandColors.turquoiseDeep, size: 24),
              SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Firmware Update',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: TypographyTokens.bodyLarge,
                        color: BrandColors.turquoiseDeep,
                      ),
                    ),
                    SizedBox(height: Spacing.xs),
                    Text(
                      'Update your device firmware over-the-air',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                    SizedBox(height: Spacing.xs),
                    Text(
                      'Latest: ${firmwareService.getLatestFirmwareVersion()}',
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Spacing.lg),
          if (firmwareService.isUpdating) ...[
            Column(
              children: [
                LinearProgressIndicator(
                  value: firmwareService.updateProgress / 100,
                  backgroundColor: BrandColors.stone,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                ),
                SizedBox(height: Spacing.sm),
                Text(
                  firmwareService.updateStatus,
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: BrandColors.turquoise,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: Spacing.xs),
                Text(
                  'Progress: ${firmwareService.updateProgress}%',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: BrandColors.turquoise,
                  ),
                ),
                SizedBox(height: Spacing.md),
                Container(
                  padding: EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: BrandColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(
                      color: BrandColors.error.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: BrandColors.error, size: 20),
                      SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          'DO NOT close this app or disconnect your device!\nClosing the app during update may brick your device.',
                          style: TextStyle(
                            fontSize: TypographyTokens.labelSmall,
                            color: BrandColors.error,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      _checkFirmwareUpdate(context, ref);
                    },
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Check for Updates'),
                    style: FilledButton.styleFrom(
                      backgroundColor: BrandColors.turquoise,
                      padding: EdgeInsets.symmetric(vertical: Spacing.md),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _checkFirmwareUpdate(
      BuildContext context, WidgetRef ref) async {
    final connectedDeviceAsync = ref.read(connectedOmiDeviceProvider);
    final connectedDevice = connectedDeviceAsync.value;

    if (connectedDevice == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No device connected'),
            backgroundColor: BrandColors.warning,
          ),
        );
      }
      return;
    }

    final firmwareService = ref.read(omiFirmwareServiceProvider);

    try {
      final updateAvailable = await firmwareService.isUpdateAvailable(
        connectedDevice,
      );

      if (!updateAvailable) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Your device is already up to date!'),
              backgroundColor: BrandColors.success,
            ),
          );
        }
        return;
      }

      if (context.mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Firmware Update Available'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current version: ${connectedDevice.firmwareRevision ?? "Unknown"}',
                ),
                Text(
                  'Latest version: ${firmwareService.getLatestFirmwareVersion()}',
                ),
                SizedBox(height: Spacing.lg),
                const Text(
                  'Keep your device nearby and do not disconnect during the update process (2-5 minutes).',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Update Now'),
              ),
            ],
          ),
        );

        if (confirmed != true) return;
      }

      await firmwareService.startFirmwareUpdate(
        device: connectedDevice,
        onProgress: (progress) {},
        onComplete: () {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Firmware update completed successfully! Device will reboot.',
                ),
                backgroundColor: BrandColors.success,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        },
        onError: (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Firmware update failed: $error'),
                backgroundColor: BrandColors.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        },
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error checking for updates: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }
}
