import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Connection state enum for server health
enum ServerConnectionState {
  connected,
  connecting,
  networkError,
  serverOffline,
  timeout,
  unknown,
}

/// Server health status model
class ServerHealthStatus {
  final bool isHealthy;
  final ServerConnectionState connectionState;
  final String message;
  final String helpText;
  final DateTime timestamp;
  final String? serverVersion;
  final Map<String, dynamic>? additionalInfo;

  ServerHealthStatus({
    required this.isHealthy,
    required this.connectionState,
    required this.message,
    this.helpText = '',
    DateTime? timestamp,
    this.serverVersion,
    this.additionalInfo,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ServerHealthStatus.healthy({String? version}) => ServerHealthStatus(
    isHealthy: true,
    connectionState: ServerConnectionState.connected,
    message: 'Connected',
    serverVersion: version,
  );

  factory ServerHealthStatus.offline() => ServerHealthStatus(
    isHealthy: false,
    connectionState: ServerConnectionState.serverOffline,
    message: 'Server offline',
    helpText: 'Parachute Computer is not responding.',
  );

  factory ServerHealthStatus.networkError(String error) => ServerHealthStatus(
    isHealthy: false,
    connectionState: ServerConnectionState.networkError,
    message: 'Network error',
    helpText: 'Unable to connect. Check your network connection.',
  );

  factory ServerHealthStatus.timeout() => ServerHealthStatus(
    isHealthy: false,
    connectionState: ServerConnectionState.timeout,
    message: 'Connection timeout',
    helpText: 'Server is taking too long to respond.',
  );

  factory ServerHealthStatus.unknown() => ServerHealthStatus(
    isHealthy: false,
    connectionState: ServerConnectionState.unknown,
    message: 'Unknown status',
    helpText: 'Unable to determine server status.',
  );
}

/// Backend health checking service
class BackendHealthService {
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  BackendHealthService({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 10),
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Check server health
  Future<ServerHealthStatus> checkHealth() async {
    if (baseUrl.isEmpty) {
      return ServerHealthStatus(
        isHealthy: false,
        connectionState: ServerConnectionState.unknown,
        message: 'No server URL configured',
        helpText: 'Configure a server URL in Settings.',
      );
    }

    try {
      final uri = Uri.parse('$baseUrl/api/health');
      final response = await _client.get(uri).timeout(timeout);

      if (response.statusCode == 200) {
        String? version;
        try {
          final data = json.decode(response.body);
          version = data['version']?.toString();
        } catch (_) {
          // Ignore JSON parse errors
        }
        return ServerHealthStatus.healthy(version: version);
      } else {
        return ServerHealthStatus(
          isHealthy: false,
          connectionState: ServerConnectionState.serverOffline,
          message: 'Server error (${response.statusCode})',
          helpText: 'Server returned an error response.',
        );
      }
    } on TimeoutException {
      return ServerHealthStatus.timeout();
    } catch (e) {
      debugPrint('[BackendHealthService] Health check error: $e');
      return ServerHealthStatus.networkError(e.toString());
    }
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
