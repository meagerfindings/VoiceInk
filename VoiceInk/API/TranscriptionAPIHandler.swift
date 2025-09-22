import Foundation
import AVFoundation
import SwiftData
import os

// Timeout helper for transcription operations
struct TranscriptionTimeoutError: Error {
    let duration: TimeInterval
}

func withTranscriptionTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Add the actual operation
        group.addTask {
            try await operation()
        }

        // Add the timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranscriptionTimeoutError(duration: seconds)
        }

        // Return the first result and cancel the rest
        guard let result = try await group.next() else {
            throw TranscriptionTimeoutError(duration: seconds)
        }
        group.cancelAll()
        return result
    }
}

/// Handles API transcription requests using VoiceInk's existing transcription pipeline
class TranscriptionAPIHandler {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APIHandler")
    let whisperState: WhisperState  // Made internal for health check access
    private let audioProcessor = AudioProcessor()
    private let modelContext: ModelContext
    weak var apiServer: TranscriptionAPIServer?
    
    // Transcription services
    private var localTranscriptionService: LocalTranscriptionService?
    private lazy var cloudTranscriptionService = CloudTranscriptionService()
    private lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private var parakeetTranscriptionService: ParakeetTranscriptionService?
    
    init(whisperState: WhisperState, modelContext: ModelContext) {
        self.whisperState = whisperState
        self.modelContext = modelContext
    }
    
    func transcribe(audioData: Data, filename: String? = nil) async throws -> Data {
        let startTime = Date()
        let fileSizeMB = Double(audioData.count) / 1024 / 1024
        logger.info("Starting transcription for \(String(format: "%.1f", fileSizeMB))MB file")

        // Detect audio format from data first
        let audioFormat = AudioFormatDetector.detectFormat(from: audioData)
        logger.info("Detected audio format: \(audioFormat.rawValue)")

        // Add stricter file size limits for API transcriptions to prevent whisper_full infinite loops
        // Large files can cause the C-level whisper_full function to hang indefinitely
        // MP3 files are especially problematic and need much stricter limits
        let maxSizeMB: Double
        let formatWarning: String

        if audioFormat == .mp3 {
            maxSizeMB = 3.0 // Very strict limit for MP3s due to frequent infinite loops
            formatWarning = " MP3 files are particularly prone to processing issues."
        } else {
            maxSizeMB = 10.0 // More generous for WAV and other formats
            formatWarning = ""
        }

        if fileSizeMB > maxSizeMB {
            logger.error("File size (\(String(format: "%.1f", fileSizeMB))MB) exceeds \(String(format: "%.1f", maxSizeMB))MB limit for \(audioFormat.rawValue.uppercased()) files in API transcriptions")
            let errorResponse = TranscriptionErrorResponse(
                success: false,
                error: ErrorDetails(
                    code: "FILE_TOO_LARGE",
                    message: "File size (\(String(format: "%.1f", fileSizeMB))MB) exceeds the \(String(format: "%.1f", maxSizeMB))MB limit for \(audioFormat.rawValue.uppercased()) files in API transcriptions.\(formatWarning) Large files can cause processing to hang indefinitely. Please use smaller audio files or split long recordings into segments."
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(errorResponse)
        }

        // Check if a model is loaded first
        guard await whisperState.currentTranscriptionModel != nil else {
            logger.error("No transcription model is currently selected or loaded")
            let errorResponse = TranscriptionErrorResponse(
                success: false,
                error: ErrorDetails(
                    code: "NO_MODEL",
                    message: "No transcription model is currently loaded. Please load a model in VoiceInk before using the API."
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(errorResponse)
        }

        // Basic audio validation - check for suspicious patterns
        if audioData.isEmpty {
            logger.error("Empty audio data received")
            let errorResponse = TranscriptionErrorResponse(
                success: false,
                error: ErrorDetails(
                    code: "INVALID_AUDIO",
                    message: "Audio data is empty"
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(errorResponse)
        }

        // Enhanced MP3-specific validation to prevent problematic files
        if audioFormat == .mp3 {
            let firstBytes = Array(audioData.prefix(16))
            logger.debug("MP3 header bytes: \(firstBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")

            // Check for MP3s that start with multiple consecutive null bytes (often corrupted)
            if firstBytes.prefix(8).allSatisfy({ $0 == 0 }) {
                logger.error("MP3 file starts with null bytes - likely corrupted and will cause processing to hang")
                let errorResponse = TranscriptionErrorResponse(
                    success: false,
                    error: ErrorDetails(
                        code: "INVALID_MP3_FORMAT",
                        message: "MP3 file appears to be corrupted (starts with null bytes). This type of file can cause processing to hang indefinitely. Please use a properly formatted MP3 file or convert to WAV format."
                    )
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                return try encoder.encode(errorResponse)
            }

            // Check for invalid MP3 header patterns
            if firstBytes.count >= 2 && !(firstBytes[0] == 0xFF && (firstBytes[1] & 0xE0) == 0xE0) &&
               !(firstBytes[0] == 0x49 && firstBytes[1] == 0x44 && firstBytes[2] == 0x33) { // Not ID3 tag
                logger.warning("⚠️ MP3 file has unusual header pattern - may cause processing issues")
            }

            // Be extra strict about MP3 file duration estimates
            if fileSizeMB > 2.0 {
                logger.warning("⚠️ Large MP3 file (\(String(format: "%.1f", fileSizeMB))MB) - high risk of processing hanging")
            }
        }
        
        // Warn about files approaching limits (adjusted for format-specific limits)
        let warningThreshold = audioFormat == .mp3 ? 1.5 : 5.0
        let dangerThreshold = audioFormat == .mp3 ? 2.5 : 8.0

        if fileSizeMB > warningThreshold {
            logger.notice("Processing large \(audioFormat.rawValue.uppercased()) file (\(String(format: "%.1f", fileSizeMB))MB) - this may take several minutes and consume significant memory")
        }
        if fileSizeMB > dangerThreshold {
            logger.warning("⚠️ Very large \(audioFormat.rawValue.uppercased()) file (\(String(format: "%.1f", fileSizeMB))MB) - approaching \(String(format: "%.1f", maxSizeMB))MB limit, high memory usage and risk of processing hanging")
        }

        // Save audio data to temporary file with correct extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(audioFormat.rawValue)

        logger.debug("💾 Saving \(String(format: "%.1f", fileSizeMB))MB audio file...")
        let writeStart = Date()
        try audioData.write(to: tempURL)
        let writeTime = Date().timeIntervalSince(writeStart)
        logger.debug("💾 Audio file saved in \(String(format: "%.3f", writeTime))s: \(tempURL.lastPathComponent)")

        defer {
            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Pre-flight duration check to catch problematic files early
        do {
            let audioAssetPrecheck = AVURLAsset(url: tempURL)
            let estimatedDuration = CMTimeGetSeconds(try await audioAssetPrecheck.load(.duration))

            // Apply stricter duration limits for MP3s
            let maxDurationMinutes: Double = audioFormat == .mp3 ? 5.0 : 15.0

            if estimatedDuration > maxDurationMinutes * 60 {
                logger.error("Pre-flight check: \(audioFormat.rawValue.uppercased()) duration (\(String(format: "%.1f", estimatedDuration / 60)) minutes) exceeds \(String(format: "%.1f", maxDurationMinutes))-minute limit")
                let errorResponse = TranscriptionErrorResponse(
                    success: false,
                    error: ErrorDetails(
                        code: "AUDIO_TOO_LONG",
                        message: "\(audioFormat.rawValue.uppercased()) duration (\(String(format: "%.1f", estimatedDuration / 60)) minutes) exceeds the \(String(format: "%.1f", maxDurationMinutes))-minute limit for API transcriptions. Long audio files can cause processing to hang indefinitely. Please split into shorter segments."
                    )
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                return try encoder.encode(errorResponse)
            }

            if audioFormat == .mp3 && estimatedDuration > 180 { // 3 minutes for MP3s
                logger.warning("⚠️ Long MP3 duration (\(String(format: "%.1f", estimatedDuration / 60)) minutes) - high risk of processing issues")
            }

            logger.info("Pre-flight check passed: \(audioFormat.rawValue.uppercased()) duration \(String(format: "%.1f", estimatedDuration))s")
        } catch {
            logger.warning("Could not determine audio duration for pre-flight check: \(error.localizedDescription)")
        }
        
        // Get current model
        guard let currentModel = await whisperState.currentTranscriptionModel else {
            throw APIError.noModelSelected
        }
        
        // Initialize services if needed
        if localTranscriptionService == nil && currentModel.provider == .local {
            localTranscriptionService = await LocalTranscriptionService(
                modelsDirectory: whisperState.modelsDirectory,
                whisperState: whisperState
            )
            
            // Check if model needs to be loaded
            if await !whisperState.isModelLoaded {
                logger.warning("Local model not loaded, attempting to load now")
                if let whisperModel = await whisperState.availableModels.first(where: { $0.name == currentModel.name }) {
                    do {
                        try await whisperState.loadModel(whisperModel)
                    } catch {
                        logger.error("Failed to load model during transcription: \(error.localizedDescription)")
                        throw APIError.transcriptionFailed("Model failed to load: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        if parakeetTranscriptionService == nil && currentModel.provider == .parakeet {
            parakeetTranscriptionService = await ParakeetTranscriptionService(
                customModelsDirectory: whisperState.parakeetModelsDirectory
            )
        }
        
        // Process audio file
        logger.info("Processing audio samples...")
        var samples = try await audioProcessor.processAudioToSamples(tempURL)
        logger.info("Audio samples processed: \(samples.count) samples")

        // Clear original audio data from memory immediately after processing
        // This helps reduce memory pressure for large files
        
        // Get final audio duration (already checked in pre-flight, but needed for processing metrics)
        let audioAsset = AVURLAsset(url: tempURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
        logger.info("Final audio duration: \(String(format: "%.1f", duration)) seconds (\(String(format: "%.1f", duration / 60)) minutes)")

        // Note: Duration limits already enforced in pre-flight check above
        
        // Create processed audio file
        let processedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        try audioProcessor.saveSamplesAsWav(samples: samples, to: processedURL)

        defer {
            try? FileManager.default.removeItem(at: processedURL)
            // Clear samples array from memory to help with garbage collection
            samples.removeAll()
        }
        
        // Transcribe using appropriate service with detailed logging
        let transcriptionStart = Date()
        var text: String

        logger.info("🔄 Starting transcription with \(currentModel.provider.rawValue) provider for \(String(format: "%.1f", fileSizeMB))MB file...")

        // Add cancellation check before transcription
        try Task.checkCancellation()

        switch currentModel.provider {
        case .local:
            logger.debug("🏠 Using local transcription service...")
            // Use much more aggressive timeouts for MP3 files and format-specific limits
            let baseTimeout: TimeInterval = audioFormat == .mp3 ? 120 : 300 // 2 min for MP3s, 5 min for others
            let maxTranscriptionTime: TimeInterval = min(baseTimeout, max(60, duration * 3)) // Much stricter than before
            logger.info("🕒 Setting local transcription timeout to \(String(format: "%.1f", maxTranscriptionTime)) seconds for \(String(format: "%.1f", duration))s \(audioFormat.rawValue.uppercased()) audio")

            do {
                text = try await withTranscriptionTimeout(seconds: maxTranscriptionTime) { [self] in
                    try await localTranscriptionService!.transcribe(audioURL: processedURL, model: currentModel)
                }
            } catch is TranscriptionTimeoutError {
                logger.error("🔴 Local transcription timed out after \(String(format: "%.1f", maxTranscriptionTime)) seconds for \(String(format: "%.1f", fileSizeMB))MB \(audioFormat.rawValue.uppercased()) file (\(String(format: "%.1f", duration))s duration)")

                // Create detailed timeout error response with format-specific guidance
                let guidance = audioFormat == .mp3 ? " MP3 files are particularly prone to infinite loops. Consider converting to WAV format." : ""
                let errorResponse = TranscriptionErrorResponse(
                    success: false,
                    error: ErrorDetails(
                        code: "TRANSCRIPTION_TIMEOUT",
                        message: "Local transcription timed out after \(String(format: "%.1f", maxTranscriptionTime/60)) minutes. File: \(String(format: "%.1f", fileSizeMB))MB \(audioFormat.rawValue.uppercased()), Duration: \(String(format: "%.1f", duration))s.\(guidance) Consider using smaller files or cloud transcription."
                    )
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let errorData = try encoder.encode(errorResponse)
                throw APIError.transcriptionFailed(String(data: errorData, encoding: .utf8) ?? "Timeout error")
            }
        case .parakeet:
            logger.debug("🦜 Using Parakeet transcription service...")
            do {
                text = try await parakeetTranscriptionService!.transcribe(audioURL: processedURL, model: currentModel)
            } catch {
                logger.error("🔴 Parakeet transcription failed: \(error.localizedDescription)")
                throw error
            }
        case .nativeApple:
            logger.debug("🍎 Using Apple native transcription service...")
            do {
                text = try await nativeAppleTranscriptionService.transcribe(audioURL: processedURL, model: currentModel)
            } catch {
                logger.error("🔴 Apple native transcription failed: \(error.localizedDescription)")
                throw error
            }
        default: // Cloud models
            logger.debug("☁️ Using cloud transcription service...")
            do {
                text = try await cloudTranscriptionService.transcribe(audioURL: processedURL, model: currentModel)
            } catch {
                logger.error("🔴 Cloud transcription failed: \(error.localizedDescription)")
                throw error
            }
        }

        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        logger.info("✅ Transcription completed in \(String(format: "%.1f", transcriptionDuration))s, result length: \(text.count) chars")

        // Add cancellation check after transcription
        try Task.checkCancellation()
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Apply word replacements if enabled
        if UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled") {
            text = WordReplacementService.shared.applyReplacements(to: text)
        }
        
        // Handle enhancement if enabled
        var enhancedText: String?
        var enhancementDuration: TimeInterval = 0
        var aiRequestSystemMessage: String?
        var aiRequestUserMessage: String?

        if let enhancementService = await whisperState.enhancementService,
           await enhancementService.isEnhancementEnabled,
           await enhancementService.isConfigured {
            do {
                let enhancementStart = Date()
                enhancedText = try await enhancementService.enhance(text).0
                enhancementDuration = Date().timeIntervalSince(enhancementStart)

                // Capture AI request messages for history display
                aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                aiRequestUserMessage = enhancementService.lastUserMessageSent
            } catch {
                logger.warning("Enhancement failed: \(error.localizedDescription)")
            }
        }
        
        // Save transcription to database
        let transcription = Transcription(
            text: text,
            duration: duration,
            enhancedText: enhancedText,
            transcriptionModelName: currentModel.displayName,
            aiEnhancementModelName: enhancedText != nil ? "AI Enhancement" : nil,
            transcriptionDuration: transcriptionDuration,
            enhancementDuration: enhancementDuration > 0 ? enhancementDuration : nil,
            source: "api",
            filename: filename,
            aiRequestSystemMessage: aiRequestSystemMessage,
            aiRequestUserMessage: aiRequestUserMessage
        )
        
        modelContext.insert(transcription)
        
        do {
            try modelContext.save()
            logger.info("API transcription saved to database")
            
            // Update API server statistics
            await apiServer?.updateAPITranscriptionStats(audioDuration: duration)
        } catch {
            logger.error("Failed to save API transcription to database: \(error)")
        }
        
        // Prepare response
        let response = TranscriptionResponse(
            success: true,
            text: text,
            enhancedText: enhancedText,
            metadata: TranscriptionMetadata(
                model: currentModel.displayName,
                language: UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto",
                duration: duration,
                processingTime: Date().timeIntervalSince(startTime),
                transcriptionTime: transcriptionDuration,
                enhancementTime: enhancementDuration > 0 ? enhancementDuration : nil,
                enhanced: enhancedText != nil,
                replacementsApplied: UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled")
            )
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(response)
    }
}

// MARK: - Response Models

struct TranscriptionResponse: Codable {
    let success: Bool
    let text: String
    let enhancedText: String?
    let metadata: TranscriptionMetadata
}

struct TranscriptionMetadata: Codable {
    let model: String
    let language: String
    let duration: Double
    let processingTime: Double
    let transcriptionTime: Double
    let enhancementTime: Double?
    let enhanced: Bool
    let replacementsApplied: Bool
}

struct TranscriptionErrorResponse: Codable {
    let success: Bool
    let error: ErrorDetails
}

struct ErrorDetails: Codable {
    let code: String
    let message: String
}

// MARK: - Errors

enum APIError: LocalizedError {
    case noModelSelected
    case audioProcessingFailed
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No transcription model is currently selected"
        case .audioProcessingFailed:
            return "Failed to process audio file"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}