/// Base error class for all Parachute app errors
sealed class AppError implements Exception {
  final String message;
  final Object? cause;

  const AppError(this.message, {this.cause});

  /// User-friendly message for display in UI
  String get userMessage => message;

  @override
  String toString() => '$runtimeType: $message';
}

class NetworkError extends AppError {
  final int? statusCode;
  const NetworkError(super.message, {super.cause, this.statusCode});

  @override
  String get userMessage => statusCode != null
    ? 'Server error ($statusCode)'
    : 'Network error - check your connection';
}

class ServerUnreachableError extends NetworkError {
  const ServerUnreachableError({super.cause}) : super('Server unreachable');

  @override
  String get userMessage => 'Cannot reach server - check URL in Settings';
}

class FileSystemError extends AppError {
  final String? path;
  const FileSystemError(super.message, {super.cause, this.path});
}

class SessionError extends AppError {
  final String? sessionId;
  const SessionError(super.message, {super.cause, this.sessionId});
}

class TranscriptionError extends AppError {
  const TranscriptionError(super.message, {super.cause});
}
