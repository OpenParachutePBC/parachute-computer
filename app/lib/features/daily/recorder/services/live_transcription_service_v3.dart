/// Legacy re-export for backwards compatibility
///
/// This file re-exports the refactored transcription service.
/// New code should import from `transcription/transcription.dart` instead.
///
/// The service was refactored from a 2000-line monolith into:
/// - `transcription/models/` - Data transfer objects
/// - `transcription/segment_persistence.dart` - Crash recovery
/// - `transcription/streaming_audio_recorder.dart` - Audio capture
/// - `transcription/transcription_queue.dart` - Processing queue
/// - `transcription/local_agreement.dart` - Streaming stability algorithm
/// - `transcription/live_transcription_service.dart` - Orchestrator
library;

// Re-export all models for backwards compatibility
export 'transcription/models/models.dart';

// Re-export the main service with the old class name alias
export 'transcription/live_transcription_service.dart' show LiveTranscriptionService;

// Provide the old class name as a typedef for gradual migration
import 'transcription/live_transcription_service.dart';

/// @deprecated Use LiveTranscriptionService instead
typedef AutoPauseTranscriptionService = LiveTranscriptionService;
