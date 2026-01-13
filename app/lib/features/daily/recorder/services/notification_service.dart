import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service for managing local notifications
///
/// Used to show recording status when app is in background.
/// Note: Only available on iOS and Android, gracefully degrades on macOS.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  bool _isSupported = true;

  /// Check if platform supports notifications
  static bool get isSupported {
    // Notifications are only supported on mobile platforms
    return Platform.isIOS || Platform.isAndroid;
  }

  /// Initialize notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Check platform support
    if (!isSupported) {
      debugPrint(
          '[NotificationService] Notifications not supported on this platform (macOS/web)');
      _isSupported = false;
      _isInitialized = true;
      return;
    }

    try {
      // Android settings
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      // iOS settings
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notifications.initialize(
        settings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Create notification channel for Android
      if (Platform.isAndroid) {
        await _createNotificationChannels();
      }

      _isInitialized = true;
      debugPrint('[NotificationService] Initialized successfully');
    } catch (e) {
      debugPrint('[NotificationService] Initialization error: $e');
      _isSupported = false;
      _isInitialized = true;
    }
  }

  /// Create Android notification channels
  Future<void> _createNotificationChannels() async {
    if (!Platform.isAndroid) return;

    const channel = AndroidNotificationChannel(
      'omi_recording',
      'Omi Recording',
      description: 'Notifications for Omi device recording status',
      importance: Importance.high,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint(
        '[NotificationService] Notification tapped: ${response.payload}');
    // TODO: Navigate to appropriate screen based on payload
  }

  /// Show recording started notification
  Future<void> showRecordingStarted() async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.show(
        0, // Notification ID
        'Recording Started',
        'Omi device is recording audio',
        _notificationDetails(),
      );
    } catch (e) {
      debugPrint('[NotificationService] Error showing notification: $e');
    }
  }

  /// Show recording stopped notification
  Future<void> showRecordingStopped({String? title}) async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.show(
        0,
        'Recording Saved',
        title ?? 'Your recording has been saved',
        _notificationDetails(),
      );
    } catch (e) {
      debugPrint('[NotificationService] Error showing notification: $e');
    }
  }

  /// Show device connected notification
  Future<void> showDeviceConnected(String deviceName) async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.show(
        1, // Different ID for persistent notification
        'Omi Connected',
        deviceName,
        _notificationDetails(ongoing: Platform.isAndroid),
      );
    } catch (e) {
      debugPrint('[NotificationService] Error showing notification: $e');
    }
  }

  /// Show device disconnected notification
  Future<void> showDeviceDisconnected() async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.show(
        1,
        'Omi Disconnected',
        'Device connection lost',
        _notificationDetails(),
      );
    } catch (e) {
      debugPrint('[NotificationService] Error showing notification: $e');
    }
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.cancelAll();
    } catch (e) {
      debugPrint('[NotificationService] Error canceling notifications: $e');
    }
  }

  /// Cancel specific notification
  Future<void> cancel(int id) async {
    if (!_isSupported || !_isInitialized) return;

    try {
      await _notifications.cancel(id);
    } catch (e) {
      debugPrint('[NotificationService] Error canceling notification: $e');
    }
  }

  /// Build notification details
  NotificationDetails _notificationDetails({bool ongoing = false}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'omi_recording',
        'Omi Recording',
        channelDescription: 'Notifications for Omi device recording status',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: ongoing, // For persistent foreground service notification
        autoCancel: !ongoing,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
