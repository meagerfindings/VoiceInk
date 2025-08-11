import Foundation
import AVFoundation
import os

/// Handles API transcription requests using VoiceInk's existing transcription pipeline
class TranscriptionAPIHandler {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APIHandler")
    let whisperState: WhisperState  // Made internal for health check access
    private let audioProcessor = AudioProcessor()
    
    // Transcription services
    private var localTranscriptionService: LocalTranscriptionService?
    private lazy var cloudTranscriptionService = CloudTranscriptionService()
    private lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private var parakeetTranscriptionService: ParakeetTranscriptionService?
    
    init(whisperState: WhisperState) {
        self.whisperState = whisperState
    }
    
    func transcribe(audioData: Data) async throws -> Data {
        let startTime = Date()
        let fileSizeMB = Double(audioData.count) / 1024 / 1024
        logger.info("Starting transcription for \(String(format: "%.1f", fileSizeMB))MB file")
        
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
        
        // Detect audio format from data
        let audioFormat = AudioFormatDetector.detectFormat(from: audioData)
        logger.info("Detected audio format: \(audioFormat.rawValue)")
        
        // For large files, log progress
        if fileSizeMB > 10 {
            logger.notice("Processing large audio file (\(String(format: "%.1f", fileSizeMB))MB)")
        }
        
        // Save audio data to temporary file with correct extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(audioFormat.rawValue)
        
        try audioData.write(to: tempURL)
        
        defer {
            // Clean up temporary file
            try? FileManager.default.removeItem(at: tempURL)
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
        let samples = try await audioProcessor.processAudioToSamples(tempURL)
        logger.info("Audio samples processed: \(samples.count) samples")
        
        // Get audio duration
        let audioAsset = AVURLAsset(url: tempURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
        logger.info("Audio duration: \(String(format: "%.1f", duration)) seconds")
        
        // Create processed audio file
        let processedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        try audioProcessor.saveSamplesAsWav(samples: samples, to: processedURL)
        
        defer {
            try? FileManager.default.removeItem(at: processedURL)
        }
        
        // Transcribe using appropriate service
        let transcriptionStart = Date()
        var text: String
        
        logger.info("Starting transcription with \(currentModel.provider.rawValue) provider...")
        
        switch currentModel.provider {
        case .local:
            text = try await localTranscriptionService!.transcribe(audioURL: processedURL, model: currentModel)
        case .parakeet:
            text = try await parakeetTranscriptionService!.transcribe(audioURL: processedURL, model: currentModel)
        case .nativeApple:
            text = try await nativeAppleTranscriptionService.transcribe(audioURL: processedURL, model: currentModel)
        default: // Cloud models
            text = try await cloudTranscriptionService.transcribe(audioURL: processedURL, model: currentModel)
        }
        
        let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
        logger.info("Transcription completed in \(String(format: "%.1f", transcriptionDuration))s")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Apply word replacements if enabled
        if UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled") {
            text = WordReplacementService.shared.applyReplacements(to: text)
        }
        
        // Handle enhancement if enabled
        var enhancedText: String?
        var enhancementDuration: TimeInterval = 0
        
        if let enhancementService = await whisperState.enhancementService,
           await enhancementService.isEnhancementEnabled,
           await enhancementService.isConfigured {
            do {
                let enhancementStart = Date()
                enhancedText = try await enhancementService.enhance(text).0
                enhancementDuration = Date().timeIntervalSince(enhancementStart)
            } catch {
                logger.warning("Enhancement failed: \(error.localizedDescription)")
            }
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