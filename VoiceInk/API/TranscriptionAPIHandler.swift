import Foundation
import AVFoundation
import os

/// Handles API transcription requests using VoiceInk's existing transcription pipeline
class TranscriptionAPIHandler {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APIHandler")
    let whisperState: WhisperState  // Made internal for health check access
    private let audioProcessor = AudioProcessor()
    private let diarizationService = SpeakerDiarizationService()
    
    // Transcription services
    private var localTranscriptionService: LocalTranscriptionService?
    private lazy var cloudTranscriptionService = CloudTranscriptionService()
    private lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private var parakeetTranscriptionService: ParakeetTranscriptionService?
    
    init(whisperState: WhisperState) {
        self.whisperState = whisperState
    }
    
    func transcribe(audioData: Data, diarizationParams: DiarizationParameters? = nil) async throws -> Data {
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
        var segments: [(start: TimeInterval, end: TimeInterval, text: String)]? = nil
        
        switch currentModel.provider {
        case .local:
            // For local, we can get detailed segments if diarization is enabled
            if diarizationParams?.enableDiarization == true {
                (text, segments) = try await transcribeWithSegments(
                    audioURL: processedURL,
                    model: currentModel,
                    enableTinydiarize: diarizationParams?.useTinydiarize ?? false
                )
            } else {
                text = try await localTranscriptionService!.transcribe(audioURL: processedURL, model: currentModel)
            }
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
        
        // Handle diarization if enabled
        var alignedResult: AlignedTranscription?
        var diarizationDuration: TimeInterval = 0
        
        if diarizationParams?.enableDiarization == true && segments != nil {
            let diarizationStart = Date()
            
            // Perform diarization
            let diarizationResult = try await diarizationService.diarize(
                audioURL: processedURL,
                mode: diarizationParams?.diarizationMode ?? .balanced,
                minSpeakers: diarizationParams?.minSpeakers,
                maxSpeakers: diarizationParams?.maxSpeakers,
                useTinydiarize: diarizationParams?.useTinydiarize ?? false
            )
            
            // Align transcription with diarization
            alignedResult = diarizationService.alignTranscriptionWithDiarization(
                transcription: text,
                timestamps: segments!.map { ($0.start, $0.end, $0.text) },
                diarization: diarizationResult
            )
            
            diarizationDuration = Date().timeIntervalSince(diarizationStart)
        }
        
        // Prepare response
        if let aligned = alignedResult {
            // Response with diarization
            let response = TranscriptionWithDiarizationResponse(
                success: true,
                text: text,
                enhancedText: enhancedText,
                segments: aligned.segments,
                speakers: aligned.speakers,
                numSpeakers: aligned.speakers.count,
                textWithSpeakers: aligned.textWithSpeakers,
                metadata: TranscriptionWithDiarizationMetadata(
                    model: currentModel.displayName,
                    language: UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto",
                    duration: duration,
                    processingTime: Date().timeIntervalSince(startTime),
                    transcriptionTime: transcriptionDuration,
                    diarizationTime: diarizationDuration > 0 ? diarizationDuration : nil,
                    enhancementTime: enhancementDuration > 0 ? enhancementDuration : nil,
                    enhanced: enhancedText != nil,
                    diarizationEnabled: true,
                    diarizationMethod: aligned.diarizationMethod,
                    replacementsApplied: UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled")
                )
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(response)
        } else {
            // Response without diarization
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
    
    /// Transcribe with detailed segments for diarization
    private func transcribeWithSegments(
        audioURL: URL,
        model: any TranscriptionModel,
        enableTinydiarize: Bool
    ) async throws -> (text: String, segments: [(start: TimeInterval, end: TimeInterval, text: String)]) {
        guard let localModel = model as? LocalModel else {
            throw APIError.noModelSelected
        }
        
        // Create a temporary whisper context for detailed transcription
        let modelURL = whisperState.modelsDirectory.appendingPathComponent(localModel.filename)
        let whisperContext = try await WhisperContext.createContext(path: modelURL.path)
        
        // Read audio samples
        let samples = try readAudioSamples(audioURL)
        
        // Set prompt
        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        await whisperContext.setPrompt(currentPrompt)
        
        // Transcribe with tinydiarize if requested
        let success = await whisperContext.fullTranscribe(samples: samples, enableTinydiarize: enableTinydiarize)
        
        guard success else {
            throw APIError.transcriptionFailed("Whisper transcription failed")
        }
        
        // Get transcription and detailed segments
        let text = await whisperContext.getTranscription()
        let detailedSegments = await whisperContext.getDetailedSegments()
        
        // Convert to simpler format
        let segments = detailedSegments.map { segment in
            (start: segment.start, end: segment.end, text: segment.text)
        }
        
        // Clean up
        await whisperContext.releaseResources()
        
        return (text, segments)
    }
    
    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: 44, to: data.count, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
        return floats
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