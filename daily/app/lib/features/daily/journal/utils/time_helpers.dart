import 'package:flutter/material.dart';

/// Parse an "HH:MM" string into a [TimeOfDay].
///
/// Falls back to [fallback] (default 21:00) if the string is malformed.
TimeOfDay parseHHMM(String hhmm, {TimeOfDay? fallback}) {
  final parts = hhmm.split(':');
  final hour = int.tryParse(parts.firstOrNull ?? '');
  final minute = int.tryParse(parts.length > 1 ? parts[1] : '');
  if (hour != null && minute != null) {
    return TimeOfDay(hour: hour, minute: minute);
  }
  return fallback ?? const TimeOfDay(hour: 21, minute: 0);
}

/// Format a [TimeOfDay] as "HH:MM" with zero-padded hours and minutes.
String formatTimeOfDay(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
