import 'package:flutter/foundation.dart';

import 'vision_service.dart';

/// Placeholder vision service for desktop platforms.
///
/// Desktop OCR is not yet implemented.
/// Future options:
/// - Ollama with vision models (LLaVA, Moondream)
/// - Tesseract OCR via FFI
/// - Cloud API fallback
class DesktopVisionService implements VisionService {
  @override
  Future<bool> isReady() async {
    // Desktop vision not yet available
    return false;
  }

  @override
  Future<VisionResult> recognizeText(String imagePath) async {
    debugPrint('[DesktopVisionService] OCR not yet available on desktop');
    return const VisionResult.empty();
  }

  @override
  Future<String> describeImage(String imagePath) async {
    // Return simple fallback
    return 'Image captured';
  }

  @override
  Future<void> dispose() async {
    // Nothing to dispose
  }
}
