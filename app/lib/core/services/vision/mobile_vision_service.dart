import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;

import 'vision_service.dart';

/// Vision service implementation using Google ML Kit.
///
/// Uses on-device text recognition for OCR.
/// Works on both iOS (Apple Vision) and Android (Google ML Kit).
/// No model download required - models are bundled with the SDK.
class MobileVisionService implements VisionService {
  mlkit.TextRecognizer? _textRecognizer;

  @override
  Future<bool> isReady() async {
    // ML Kit is always ready - models are bundled with the SDK
    return true;
  }

  @override
  Future<VisionResult> recognizeText(String imagePath) async {
    try {
      _textRecognizer ??= mlkit.TextRecognizer();

      final inputImage = mlkit.InputImage.fromFilePath(imagePath);
      final recognizedText = await _textRecognizer!.processImage(inputImage);

      // Convert ML Kit result to our VisionResult
      final blocks = recognizedText.blocks.map((block) {
        final lines = block.lines.map((line) {
          return TextLine(
            text: line.text,
            boundingBox: _rectToList(line.boundingBox),
            // ML Kit provides confidence per element, not per line
            confidence: null,
          );
        }).toList();

        return TextBlock(
          text: block.text,
          boundingBox: _rectToList(block.boundingBox),
          // ML Kit TextBlock doesn't expose confidence directly
          confidence: null,
          lines: lines,
        );
      }).toList();

      return VisionResult(
        text: recognizedText.text,
        blocks: blocks,
        confidence: null, // Overall confidence not available from ML Kit
      );
    } catch (e) {
      debugPrint('[MobileVisionService] Error recognizing text: $e');
      return const VisionResult.empty();
    }
  }

  @override
  Future<String> describeImage(String imagePath) async {
    // For now, return OCR text as the description.
    // Future: Use Gemma 3n multimodal for rich descriptions.
    final result = await recognizeText(imagePath);

    if (result.hasText) {
      // Return first ~200 chars of text as description
      final text = result.text;
      if (text.length > 200) {
        return '${text.substring(0, 200)}...';
      }
      return text;
    }

    return 'Image captured';
  }

  @override
  Future<void> dispose() async {
    await _textRecognizer?.close();
    _textRecognizer = null;
  }

  /// Convert Rect to list [left, top, width, height]
  List<double>? _rectToList(dynamic rect) {
    if (rect == null) return null;
    try {
      // ML Kit returns Rect
      return [
        rect.left.toDouble(),
        rect.top.toDouble(),
        rect.width.toDouble(),
        rect.height.toDouble(),
      ];
    } catch (e) {
      return null;
    }
  }
}
