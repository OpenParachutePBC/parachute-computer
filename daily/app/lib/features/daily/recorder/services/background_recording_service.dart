import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Callback for handling recording state changes
typedef RecordingStateCallback = void Function(bool isRecording);

/// Service for managing background recording capabilities
///
/// Handles:
/// - Android foreground service for background recording
/// - iOS background audio session
/// - App lifecycle monitoring
/// - Recording state persistence
class BackgroundRecordingService with WidgetsBindingObserver {
  static final BackgroundRecordingService _instance =
      BackgroundRecordingService._internal();
  factory BackgroundRecordingService() => _instance;
  BackgroundRecordingService._internal();

  bool _isInitialized = false;
  bool _isRecording = false;
  bool _isInBackground = false;
  DateTime? _recordingStartTime;
  String? _currentRecordingPath;

  // Callbacks for state changes
  final List<RecordingStateCallback> _stateCallbacks = [];
  final _backgroundStateController = StreamController<bool>.broadcast();

  /// Stream of background state changes (true = in background)
  Stream<bool> get backgroundStateStream => _backgroundStateController.stream;

  /// Whether the app is currently in the background
  bool get isInBackground => _isInBackground;

  /// Whether a recording is active
  bool get isRecording => _isRecording;

  /// Duration since recording started
  Duration get recordingDuration {
    if (_recordingStartTime == null) return Duration.zero;
    return DateTime.now().difference(_recordingStartTime!);
  }

  /// Initialize the background recording service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Register lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Initialize foreground task for Android
    if (Platform.isAndroid) {
      await _initializeForegroundTask();
    }

    _isInitialized = true;
    debugPrint('[BackgroundRecording] Service initialized');
  }

  /// Initialize Android foreground task
  Future<void> _initializeForegroundTask() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'parachute_recording',
        channelName: 'Recording Service',
        channelDescription:
            'Keeps recording active when app is in background',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );

    debugPrint('[BackgroundRecording] Foreground task initialized');
  }

  /// Start foreground service for background recording
  Future<bool> startForegroundService() async {
    if (!Platform.isAndroid) {
      // iOS uses background audio mode configured in Info.plist
      debugPrint('[BackgroundRecording] iOS uses native background audio');
      return true;
    }

    try {
      // Request notification permission on Android 13+
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // Start the foreground service
      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Recording in progress',
        notificationText: 'Tap to return to Parachute Daily',
        notificationButtons: [
          const NotificationButton(id: 'stop', text: 'Stop'),
        ],
        callback: _foregroundTaskCallback,
      );

      debugPrint('[BackgroundRecording] Foreground service started: $result');
      return result is ServiceRequestSuccess;
    } catch (e) {
      debugPrint('[BackgroundRecording] Error starting foreground service: $e');
      return false;
    }
  }

  /// Stop foreground service
  Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;

    try {
      await FlutterForegroundTask.stopService();
      debugPrint('[BackgroundRecording] Foreground service stopped');
    } catch (e) {
      debugPrint('[BackgroundRecording] Error stopping foreground service: $e');
    }
  }

  /// Update foreground notification with recording duration
  Future<void> updateNotification(Duration duration) async {
    if (!Platform.isAndroid || !_isRecording) return;

    try {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      final text = 'Recording: ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

      await FlutterForegroundTask.updateService(
        notificationTitle: 'Recording in progress',
        notificationText: text,
      );
    } catch (e) {
      debugPrint('[BackgroundRecording] Error updating notification: $e');
    }
  }

  /// Called when recording starts
  Future<void> onRecordingStarted(String? recordingPath) async {
    _isRecording = true;
    _recordingStartTime = DateTime.now();
    _currentRecordingPath = recordingPath;

    // Start foreground service on Android
    await startForegroundService();

    // Persist recording state for crash recovery
    await _persistRecordingState();

    // Notify listeners
    for (final callback in _stateCallbacks) {
      callback(true);
    }

    debugPrint('[BackgroundRecording] Recording started, path: $recordingPath');
  }

  /// Called when recording stops
  Future<void> onRecordingStopped() async {
    _isRecording = false;
    _recordingStartTime = null;
    _currentRecordingPath = null;

    // Stop foreground service
    await stopForegroundService();

    // Clear persisted state
    await _clearRecordingState();

    // Notify listeners
    for (final callback in _stateCallbacks) {
      callback(false);
    }

    debugPrint('[BackgroundRecording] Recording stopped');
  }

  /// Register a callback for recording state changes
  void addStateCallback(RecordingStateCallback callback) {
    _stateCallbacks.add(callback);
  }

  /// Remove a state callback
  void removeStateCallback(RecordingStateCallback callback) {
    _stateCallbacks.remove(callback);
  }

  // SharedPreferences keys for persistence
  static const String _keyIsRecording = 'bg_recording_active';
  static const String _keyRecordingPath = 'bg_recording_path';
  static const String _keyRecordingStartTime = 'bg_recording_start_time';

  /// Persist recording state for crash recovery
  Future<void> _persistRecordingState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyIsRecording, true);
      if (_currentRecordingPath != null) {
        await prefs.setString(_keyRecordingPath, _currentRecordingPath!);
      }
      if (_recordingStartTime != null) {
        await prefs.setInt(
          _keyRecordingStartTime,
          _recordingStartTime!.millisecondsSinceEpoch,
        );
      }
      debugPrint('[BackgroundRecording] State persisted: $_currentRecordingPath');
    } catch (e) {
      debugPrint('[BackgroundRecording] Failed to persist state: $e');
    }
  }

  /// Clear persisted recording state
  Future<void> _clearRecordingState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyIsRecording);
      await prefs.remove(_keyRecordingPath);
      await prefs.remove(_keyRecordingStartTime);
      debugPrint('[BackgroundRecording] Persisted state cleared');
    } catch (e) {
      debugPrint('[BackgroundRecording] Failed to clear state: $e');
    }
  }

  /// Check for interrupted recording on app start
  ///
  /// Returns the path to an interrupted recording WAV file if one exists,
  /// or null if no interrupted recording was found.
  Future<String?> checkForInterruptedRecording() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wasRecording = prefs.getBool(_keyIsRecording) ?? false;

      if (!wasRecording) {
        return null;
      }

      final recordingPath = prefs.getString(_keyRecordingPath);
      if (recordingPath == null) {
        await _clearRecordingState();
        return null;
      }

      // Check if the file exists
      final file = File(recordingPath);
      if (!await file.exists()) {
        debugPrint('[BackgroundRecording] Interrupted recording file not found');
        await _clearRecordingState();
        return null;
      }

      // Check file size - if too small, it's not a valid recording
      final size = await file.length();
      if (size < 1024) {
        // Less than 1KB - probably just header
        debugPrint('[BackgroundRecording] Interrupted recording too small: $size bytes');
        await file.delete();
        await _clearRecordingState();
        return null;
      }

      final startTime = prefs.getInt(_keyRecordingStartTime);
      final duration = startTime != null
          ? DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(startTime))
          : null;

      debugPrint(
        '[BackgroundRecording] Found interrupted recording: $recordingPath '
        '(${size ~/ 1024}KB, ${duration?.inSeconds ?? "?"}s)',
      );

      // Clear the state so we don't keep recovering the same file
      await _clearRecordingState();

      return recordingPath;
    } catch (e) {
      debugPrint('[BackgroundRecording] Error checking for interrupted recording: $e');
      return null;
    }
  }

  /// Handle app lifecycle changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[BackgroundRecording] Lifecycle state: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _isInBackground = true;
        _backgroundStateController.add(true);
        if (_isRecording) {
          debugPrint('[BackgroundRecording] App backgrounded while recording');
          // Recording continues via foreground service
        }
        break;

      case AppLifecycleState.resumed:
        _isInBackground = false;
        _backgroundStateController.add(false);
        if (_isRecording) {
          debugPrint('[BackgroundRecording] App resumed, recording active');
        }
        break;

      case AppLifecycleState.detached:
        debugPrint('[BackgroundRecording] App detached');
        // Foreground service keeps recording alive
        break;

      case AppLifecycleState.hidden:
        debugPrint('[BackgroundRecording] App hidden');
        break;
    }
  }

  /// Dispose the service
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundStateController.close();
    _stateCallbacks.clear();
    debugPrint('[BackgroundRecording] Service disposed');
  }
}

/// Foreground task callback - runs in a separate isolate on Android
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

/// Task handler for foreground service
class _RecordingTaskHandler extends TaskHandler {
  int _elapsedSeconds = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[RecordingTaskHandler] Task started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _elapsedSeconds += 5;
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = _elapsedSeconds % 60;

    FlutterForegroundTask.updateService(
      notificationTitle: 'Recording in progress',
      notificationText: 'Duration: ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('[RecordingTaskHandler] Task destroyed');
  }

  @override
  void onReceiveData(Object data) {
    debugPrint('[RecordingTaskHandler] Received data: $data');
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      debugPrint('[RecordingTaskHandler] Stop button pressed');
      // Send message to main isolate to stop recording
      FlutterForegroundTask.sendDataToMain('stop_recording');
    }
  }

  @override
  void onNotificationPressed() {
    debugPrint('[RecordingTaskHandler] Notification pressed');
    // Bring app to foreground
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    debugPrint('[RecordingTaskHandler] Notification dismissed');
  }
}
