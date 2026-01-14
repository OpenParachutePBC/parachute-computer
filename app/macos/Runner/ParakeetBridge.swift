import FlutterMacOS
import Foundation
import FluidAudio
import AVFoundation

/// Flutter bridge for FluidAudio Parakeet ASR
/// Provides async transcription and speaker diarization via platform channels
class ParakeetBridge {
    static let shared = ParakeetBridge()

    private var asrManager: AsrManager?
    private var models: AsrModels?
    private var isInitialized = false

    // Speaker diarization
    private var diarizerManager: OfflineDiarizerManager?
    private var isDiarizerInitialized = false

    private init() {}

    /// Initialize Parakeet models (download if needed)
    func initialize(version: AsrModelVersion = .v3, result: @escaping FlutterResult) {
        Task {
            do {
                // Download and load models
                let models = try await AsrModels.downloadAndLoad(version: version)
                self.models = models

                // Initialize ASR manager
                let config = ASRConfig.default
                let manager = AsrManager(config: config)
                try await manager.initialize(models: models)
                self.asrManager = manager
                self.isInitialized = true

                // Success
                await MainActor.run {
                    result(["status": "success", "version": version == .v3 ? "v3" : "v2"])
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(
                        code: "INITIALIZATION_FAILED",
                        message: "Failed to initialize Parakeet: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }

    /// Transcribe audio file (WAV format, 16kHz mono)
    func transcribe(audioPath: String, result: @escaping FlutterResult) {
        guard isInitialized, let manager = asrManager else {
            result(FlutterError(
                code: "NOT_INITIALIZED",
                message: "Parakeet not initialized. Call initialize() first.",
                details: nil
            ))
            return
        }

        Task {
            do {
                // Load audio samples from WAV file
                let samples = try await loadAudioSamples(from: audioPath)

                // Transcribe
                let transcription = try await manager.transcribe(samples)

                // Return text (Parakeet doesn't provide language detection)
                await MainActor.run {
                    result(["text": transcription.text, "language": "auto"])
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(
                        code: "TRANSCRIPTION_FAILED",
                        message: "Failed to transcribe audio: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }

    /// Check if models are initialized
    func isReady(result: FlutterResult) {
        result(["ready": isInitialized])
    }

    /// Get model info
    func getModelInfo(result: FlutterResult) {
        guard isInitialized else {
            result(["initialized": false])
            return
        }

        result([
            "initialized": true,
            "version": "v3", // TODO: Track actual version
            "languages": 25 // v3 supports 25 European languages
        ])
    }

    /// Check if models are already downloaded (without initializing)
    func areModelsDownloaded(result: FlutterResult) {
        // Check if model files exist on disk
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let modelPath = supportDir?.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")

        let modelsExist = modelPath.flatMap { fileManager.fileExists(atPath: $0.path) } ?? false
        result(["downloaded": modelsExist])
    }

    // MARK: - Speaker Diarization

    /// Initialize speaker diarization models
    func initializeDiarizer(result: @escaping FlutterResult) {
        Task {
            do {
                let config = OfflineDiarizerConfig()
                let manager = OfflineDiarizerManager(config: config)
                try await manager.prepareModels()

                self.diarizerManager = manager
                self.isDiarizerInitialized = true

                await MainActor.run {
                    result(["status": "success"])
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(
                        code: "DIARIZER_INIT_FAILED",
                        message: "Failed to initialize diarizer: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }

    /// Perform speaker diarization on audio file
    func diarizeAudio(audioPath: String, result: @escaping FlutterResult) {
        guard isDiarizerInitialized, let manager = diarizerManager else {
            result(FlutterError(
                code: "DIARIZER_NOT_INITIALIZED",
                message: "Diarizer not initialized. Call initializeDiarizer() first.",
                details: nil
            ))
            return
        }

        Task {
            do {
                let url = URL(fileURLWithPath: audioPath)
                let diarizationResult = try await manager.process(url)

                // Convert segments to Flutter-friendly format
                let segments = diarizationResult.segments.map { segment in
                    return [
                        "speakerId": segment.speakerId,
                        "startTimeSeconds": segment.startTimeSeconds,
                        "endTimeSeconds": segment.endTimeSeconds
                    ] as [String: Any]
                }

                await MainActor.run {
                    result(["segments": segments])
                }
            } catch {
                await MainActor.run {
                    result(FlutterError(
                        code: "DIARIZATION_FAILED",
                        message: "Failed to diarize audio: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }

    /// Check if diarizer is ready
    func isDiarizerReady(result: FlutterResult) {
        result(["ready": isDiarizerInitialized])
    }

    // MARK: - Audio Loading

    /// Load audio samples from audio file (WAV or Opus)
    /// Automatically converts Opus to WAV if needed using AVFoundation
    private func loadAudioSamples(from path: String) async throws -> [Float] {
        let url = URL(fileURLWithPath: path)

        // Convert Opus to WAV if needed
        let wavURL: URL
        var needsCleanup = false

        if path.hasSuffix(".opus") {
            print("[ParakeetBridge] Converting Opus to WAV: \(path)")
            wavURL = try await convertOpusToWav(from: url)
            needsCleanup = true
        } else {
            wavURL = url
        }

        defer {
            // Clean up temporary WAV file if created
            if needsCleanup {
                try? FileManager.default.removeItem(at: wavURL)
                print("[ParakeetBridge] Cleaned up temporary WAV: \(wavURL.path)")
            }
        }

        // Read file data
        guard let data = try? Data(contentsOf: wavURL) else {
            throw NSError(domain: "ParakeetBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read audio file at: \(wavURL.path)"
            ])
        }

        // Parse WAV header (skip first 44 bytes)
        let headerSize = 44
        guard data.count > headerSize else {
            throw NSError(domain: "ParakeetBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid WAV file: too small"
            ])
        }

        // Extract PCM samples (int16 little-endian)
        let audioData = data.subdata(in: headerSize..<data.count)
        let sampleCount = audioData.count / 2 // 2 bytes per int16 sample

        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)

        audioData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // Convert int16 to float [-1.0, 1.0]
                let sample = Float(int16Ptr[i]) / 32768.0
                samples.append(sample)
            }
        }

        return samples
    }

    /// Convert Opus file to WAV using AVFoundation
    /// Returns URL to temporary WAV file
    private func convertOpusToWav(from opusURL: URL) async throws -> URL {
        print("[ParakeetBridge] Converting Opus to WAV: \(opusURL.path)")

        let asset = AVURLAsset(url: opusURL)

        // Get audio track
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "ParakeetBridge", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No audio track found in Opus file"
            ])
        }

        // Create reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16000,  // 16kHz
            AVNumberOfChannelsKey: 1  // Mono
        ])
        reader.add(readerOutput)

        // Create writer
        let tempDir = FileManager.default.temporaryDirectory
        let wavURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        let writer = try AVAssetWriter(outputURL: wavURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1
        ])
        writer.add(writerInput)

        // Start reading/writing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // Mark these as nonisolated(unsafe) since AVFoundation guarantees thread-safety internally
            nonisolated(unsafe) let input = writerInput
            nonisolated(unsafe) let output = readerOutput
            nonisolated(unsafe) let assetWriter = writer

            input.requestMediaDataWhenReady(on: DispatchQueue(label: "opus.conversion")) {
                while input.isReadyForMoreMediaData {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        Task {
                            await assetWriter.finishWriting()
                            if assetWriter.status == .completed {
                                print("[ParakeetBridge] Converted Opus to WAV: \(wavURL.path)")
                                continuation.resume(returning: wavURL)
                            } else {
                                let error = assetWriter.error?.localizedDescription ?? "unknown error"
                                continuation.resume(throwing: NSError(domain: "ParakeetBridge", code: 4, userInfo: [
                                    NSLocalizedDescriptionKey: "Opus to WAV conversion failed: \(error)"
                                ]))
                            }
                        }
                        return
                    }
                    input.append(sampleBuffer)
                }
            }
        }
    }

    /// Resample audio to target sample rate and channel count
    private func resampleAudio(from url: URL, to sampleRate: Int, channels: Int) async throws -> URL {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "ParakeetBridge", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "No audio track found"
            ])
        }

        // Check if resampling is needed
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else {
            throw NSError(domain: "ParakeetBridge", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "No format description found"
            ])
        }

        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        let currentSampleRate = audioStreamBasicDescription?.pointee.mSampleRate ?? 0
        let currentChannels = audioStreamBasicDescription?.pointee.mChannelsPerFrame ?? 0

        // If already correct format, return original URL
        if Int(currentSampleRate) == sampleRate && Int(currentChannels) == channels {
            return url
        }

        // Create reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ])
        reader.add(readerOutput)

        // Create writer
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ])
        writer.add(writerInput)

        // Start reading/writing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            // Mark these as nonisolated(unsafe) since AVFoundation guarantees thread-safety internally
            nonisolated(unsafe) let input = writerInput
            nonisolated(unsafe) let output = readerOutput
            nonisolated(unsafe) let assetWriter = writer

            input.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.resampling")) {
                while input.isReadyForMoreMediaData {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        Task {
                            await assetWriter.finishWriting()
                            if assetWriter.status == .completed {
                                continuation.resume(returning: outputURL)
                            } else {
                                continuation.resume(throwing: NSError(domain: "ParakeetBridge", code: 7, userInfo: [
                                    NSLocalizedDescriptionKey: "Audio resampling failed: \(assetWriter.error?.localizedDescription ?? "unknown error")"
                                ]))
                            }
                        }
                        return
                    }
                    input.append(sampleBuffer)
                }
            }
        }
    }
}
