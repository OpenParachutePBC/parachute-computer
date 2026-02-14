/// Input validation utilities for the Parachute app
class Validators {
  /// Validates that a string is not empty and doesn't exceed max length
  static String? validateTitle(String? value, {int maxLength = 100}) {
    if (value == null || value.trim().isEmpty) {
      return 'Title cannot be empty';
    }

    if (value.trim().length > maxLength) {
      return 'Title must be $maxLength characters or less';
    }

    return null;
  }

  /// Validates an OpenAI API key format
  /// OpenAI keys start with 'sk-' and are typically 51 characters
  static String? validateApiKey(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'API key cannot be empty';
    }

    final trimmed = value.trim();

    if (!trimmed.startsWith('sk-')) {
      return 'Invalid API key format (should start with sk-)';
    }

    if (trimmed.length < 20) {
      return 'API key appears too short';
    }

    return null;
  }

  /// Validates tag input
  static String? validateTag(String? value, {int maxLength = 50}) {
    if (value == null || value.trim().isEmpty) {
      return null; // Tags are optional
    }

    if (value.trim().length > maxLength) {
      return 'Tag must be $maxLength characters or less';
    }

    // Ensure tags don't contain special characters
    final invalidChars = RegExp(r'[^\w\s-]');
    if (invalidChars.hasMatch(value)) {
      return 'Tags can only contain letters, numbers, spaces, and hyphens';
    }

    return null;
  }

  /// Sanitizes user input by trimming whitespace
  static String sanitize(String input) {
    return input.trim();
  }

  /// Validates file path exists and is accessible
  static bool isValidFilePath(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }

    // Basic validation - actual file existence should be checked elsewhere
    return path.contains('/') || path.contains('\\');
  }
}
