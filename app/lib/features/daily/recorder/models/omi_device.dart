import 'package:parachute/features/daily/recorder/services/omi/models.dart';

/// Model representing an Omi wearable device
///
/// This model stores information about a paired Omi device including
/// its ID, name, type, and hardware/firmware details.
class OmiDevice {
  final String id;
  final String name;
  final DeviceType type;
  final int rssi; // Signal strength
  final String? modelNumber;
  final String? firmwareRevision;
  final String? hardwareRevision;
  final String? manufacturerName;

  OmiDevice({
    required this.id,
    required this.name,
    required this.type,
    this.rssi = 0,
    this.modelNumber,
    this.firmwareRevision,
    this.hardwareRevision,
    this.manufacturerName,
  })  : assert(id.isNotEmpty, 'Device ID cannot be empty'),
        assert(name.isNotEmpty, 'Device name cannot be empty');

  /// Create an empty/null device
  factory OmiDevice.empty() {
    return OmiDevice(
      id: '',
      name: '',
      type: DeviceType.omi,
      rssi: 0,
    );
  }

  /// Get short version of device ID (last 6 characters)
  String getShortId() {
    return OmiDevice.shortId(id);
  }

  static String shortId(String id) {
    try {
      return id.replaceAll(':', '').split('-').last.substring(0, 6);
    } catch (e) {
      return id.length > 6 ? id.substring(0, 6) : id;
    }
  }

  /// Create a copy with updated fields
  OmiDevice copyWith({
    String? id,
    String? name,
    DeviceType? type,
    int? rssi,
    String? modelNumber,
    String? firmwareRevision,
    String? hardwareRevision,
    String? manufacturerName,
  }) {
    return OmiDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      rssi: rssi ?? this.rssi,
      modelNumber: modelNumber ?? this.modelNumber,
      firmwareRevision: firmwareRevision ?? this.firmwareRevision,
      hardwareRevision: hardwareRevision ?? this.hardwareRevision,
      manufacturerName: manufacturerName ?? this.manufacturerName,
    );
  }

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.index,
      'rssi': rssi,
      'modelNumber': modelNumber,
      'firmwareRevision': firmwareRevision,
      'hardwareRevision': hardwareRevision,
      'manufacturerName': manufacturerName,
    };
  }

  /// Create from JSON
  factory OmiDevice.fromJson(Map<String, dynamic> json) {
    return OmiDevice(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] != null
          ? DeviceType.values[json['type'] as int]
          : DeviceType.omi,
      rssi: json['rssi'] as int? ?? 0,
      modelNumber: json['modelNumber'] as String?,
      firmwareRevision: json['firmwareRevision'] as String?,
      hardwareRevision: json['hardwareRevision'] as String?,
      manufacturerName: json['manufacturerName'] as String?,
    );
  }

  @override
  String toString() {
    return 'OmiDevice{id: $id, name: $name, type: $type, firmware: $firmwareRevision}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OmiDevice && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
