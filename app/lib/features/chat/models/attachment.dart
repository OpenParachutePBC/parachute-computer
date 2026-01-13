import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Supported attachment types
enum AttachmentType {
  image,
  pdf,
  text,
  code,
  archive,
  audio,
  video,
  unknown,
}

/// File extension to attachment type mapping
AttachmentType getAttachmentType(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'webp':
      return AttachmentType.image;
    case 'pdf':
      return AttachmentType.pdf;
    case 'txt':
    case 'md':
    case 'markdown':
      return AttachmentType.text;
    case 'dart':
    case 'py':
    case 'js':
    case 'ts':
    case 'java':
    case 'kt':
    case 'swift':
    case 'go':
    case 'rs':
    case 'c':
    case 'cpp':
    case 'h':
    case 'hpp':
    case 'json':
    case 'yaml':
    case 'yml':
    case 'xml':
    case 'html':
    case 'css':
    case 'sql':
    case 'sh':
    case 'bash':
    case 'toml':
    case 'ini':
    case 'env':
    case 'gitignore':
    case 'dockerfile':
      return AttachmentType.code;
    case 'zip':
    case 'tar':
    case 'gz':
    case 'tgz':
    case 'rar':
    case '7z':
    case 'bz2':
    case 'xz':
      return AttachmentType.archive;
    case 'mp3':
    case 'wav':
    case 'ogg':
    case 'opus':
    case 'm4a':
    case 'flac':
    case 'aac':
      return AttachmentType.audio;
    case 'mp4':
    case 'mov':
    case 'avi':
    case 'mkv':
    case 'webm':
      return AttachmentType.video;
    default:
      return AttachmentType.unknown;
  }
}

/// Get MIME type for a file path
String getMimeType(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'md':
    case 'markdown':
      return 'text/markdown';
    case 'json':
      return 'application/json';
    case 'xml':
      return 'application/xml';
    case 'html':
      return 'text/html';
    case 'css':
      return 'text/css';
    case 'js':
      return 'text/javascript';
    case 'ts':
      return 'text/typescript';
    default:
      return 'application/octet-stream';
  }
}

/// Represents a file attachment in a chat message
class ChatAttachment {
  /// Unique identifier for the attachment
  final String id;

  /// Original file name
  final String fileName;

  /// Full path to the file (local path before upload, asset path after)
  final String filePath;

  /// MIME type of the file
  final String mimeType;

  /// File size in bytes
  final int sizeBytes;

  /// Attachment type category
  final AttachmentType type;

  /// Base64 encoded data (for sending to API)
  final String? base64Data;

  /// Thumbnail data for images (base64)
  final String? thumbnailBase64;

  /// Text content (for text/code files, preview)
  final String? textPreview;

  const ChatAttachment({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.type,
    this.base64Data,
    this.thumbnailBase64,
    this.textPreview,
  });

  /// Create an attachment from a local file
  static Future<ChatAttachment> fromFile(File file) async {
    final path = file.path;
    final fileName = path.split(Platform.pathSeparator).last;
    final type = getAttachmentType(path);
    final mimeType = getMimeType(path);
    final bytes = await file.readAsBytes();
    final sizeBytes = bytes.length;

    String? textPreview;

    // For text/code files, try to read content for preview
    if (type == AttachmentType.text || type == AttachmentType.code) {
      try {
        final content = await file.readAsString();
        // Limit preview to first 500 chars
        textPreview = content.length > 500
            ? '${content.substring(0, 500)}...'
            : content;
      } catch (_) {
        // If we can't read as string, that's fine - no preview
      }
    }

    // Always encode as base64 - let the agent figure out what to do with it
    final base64Data = base64Encode(bytes);

    return ChatAttachment(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: fileName,
      filePath: path,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      type: type,
      base64Data: base64Data,
      textPreview: textPreview,
    );
  }

  /// Create from bytes (e.g., from image picker)
  static ChatAttachment fromBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) {
    final type = getAttachmentType(fileName);

    String? textPreview;
    if (type == AttachmentType.text || type == AttachmentType.code) {
      try {
        final content = utf8.decode(bytes);
        textPreview = content.length > 500
            ? '${content.substring(0, 500)}...'
            : content;
      } catch (_) {}
    }

    return ChatAttachment(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: fileName,
      filePath: fileName, // Will be updated after saving
      mimeType: mimeType,
      sizeBytes: bytes.length,
      type: type,
      base64Data: base64Encode(bytes),
      textPreview: textPreview,
    );
  }

  /// Convert to JSON for API
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fileName': fileName,
      'filePath': filePath,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'type': type.name,
      'base64Data': base64Data,
    };
  }

  /// Create from JSON (for displaying in messages)
  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    return ChatAttachment(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: json['fileName'] as String? ?? json['file_name'] as String? ?? 'file',
      filePath: json['filePath'] as String? ?? json['file_path'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? json['mime_type'] as String? ?? 'application/octet-stream',
      sizeBytes: json['sizeBytes'] as int? ?? json['size_bytes'] as int? ?? 0,
      type: AttachmentType.values.firstWhere(
        (t) => t.name == (json['type'] as String?),
        orElse: () => AttachmentType.unknown,
      ),
      base64Data: json['base64Data'] as String? ?? json['base64_data'] as String?,
      textPreview: json['textPreview'] as String? ?? json['text_preview'] as String?,
    );
  }

  /// Human-readable file size
  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Whether this is an image that can be displayed inline
  bool get isDisplayableImage => type == AttachmentType.image;

  /// Whether this is a text-based file that can be previewed
  bool get hasTextPreview => textPreview != null;

  /// Get bytes from base64 data
  Uint8List? get bytes {
    if (base64Data == null) return null;
    return base64Decode(base64Data!);
  }
}
