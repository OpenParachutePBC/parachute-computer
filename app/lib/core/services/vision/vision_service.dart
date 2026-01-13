/// Abstract interface for vision/OCR services.
///
/// Provides text recognition and image description capabilities.
/// Currently implemented with Google ML Kit for mobile platforms.
/// Desktop support planned for future (Ollama vision models, Tesseract, etc.)
abstract class VisionService {
  /// Check if the vision service is ready to process images.
  /// For ML Kit, this is always true (no model download required).
  Future<bool> isReady();

  /// Recognize text in an image (OCR).
  ///
  /// Returns [VisionResult] containing extracted text and metadata.
  /// Works for printed text, handwriting, and mixed content.
  Future<VisionResult> recognizeText(String imagePath);

  /// Generate a description of the image.
  ///
  /// Currently returns OCR text as the description.
  /// Future: Use multimodal LLM (Gemma 3n) for rich descriptions.
  Future<String> describeImage(String imagePath);

  /// Dispose of resources.
  Future<void> dispose();
}

/// Result of vision/OCR processing.
class VisionResult {
  /// The full extracted text, with blocks separated by newlines.
  final String text;

  /// Individual text blocks with position information.
  final List<TextBlock> blocks;

  /// Average confidence score (0.0 - 1.0), if available.
  final double? confidence;

  /// Whether any text was detected.
  bool get hasText => text.isNotEmpty;

  const VisionResult({
    required this.text,
    this.blocks = const [],
    this.confidence,
  });

  /// Create an empty result (no text detected).
  const VisionResult.empty()
      : text = '',
        blocks = const [],
        confidence = null;
}

/// A block of recognized text with position information.
class TextBlock {
  /// The recognized text content.
  final String text;

  /// Bounding box in image coordinates [left, top, width, height].
  final List<double>? boundingBox;

  /// Confidence score for this block (0.0 - 1.0).
  final double? confidence;

  /// Lines within this block.
  final List<TextLine> lines;

  const TextBlock({
    required this.text,
    this.boundingBox,
    this.confidence,
    this.lines = const [],
  });
}

/// A line of text within a block.
class TextLine {
  /// The text content of the line.
  final String text;

  /// Bounding box in image coordinates.
  final List<double>? boundingBox;

  /// Confidence score for this line.
  final double? confidence;

  const TextLine({
    required this.text,
    this.boundingBox,
    this.confidence,
  });
}
