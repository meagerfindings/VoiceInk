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
        
        // Save audio data to temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
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
        if localTranscriptionService == nil {
            localTranscriptionService = await LocalTranscriptionService(
                modelsDirectory: whisperState.modelsDirectory,
                whisperState: whisperState
            )
        }
        
        if parakeetTranscriptionService == nil {
            parakeetTranscriptionService = await ParakeetTranscriptionService(
                customModelsDirectory: whisperState.parakeetModelsDirectory
            )
        }
        
        // Process audio file
        let samples = try await audioProcessor.processAudioToSamples(tempURL)
        
        // Get audio duration
        let audioAsset = AVURLAsset(url: tempURL)
        let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
        
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