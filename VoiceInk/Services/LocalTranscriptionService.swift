import Foundation
import AVFoundation
import os

class LocalTranscriptionService: TranscriptionService {
    
    private var whisperContext: WhisperContext?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalTranscriptionService")
    private let modelsDirectory: URL
    private weak var whisperState: WhisperState?
    
    init(modelsDirectory: URL, whisperState: WhisperState? = nil) {
        self.modelsDirectory = modelsDirectory
        self.whisperState = whisperState
    }
    
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model.provider == .local else {
            throw WhisperStateError.modelLoadFailed
        }
        
        logger.notice("Initiating local transcription for model: \(model.displayName)")
        
        // Check if the required model is already loaded in WhisperState
        if let whisperState = whisperState,
           await whisperState.isModelLoaded,
           let loadedContext = await whisperState.whisperContext,
            let currentModel = await whisperState.currentTranscriptionModel,
            currentModel.provider == .local,
            currentModel.name == model.name {
            
            logger.notice("✅ Using already loaded model: \(model.name)")
            whisperContext = loadedContext
        } else {
            // Model not loaded or wrong model loaded, proceed with loading
            // Resolve the on-disk URL using WhisperState.availableModels (covers imports)
            let resolvedURL: URL? = await whisperState?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("Model file not found for: \(model.name)")
                throw WhisperStateError.modelLoadFailed
            }
            
            logger.notice("Loading model: \(model.name)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("Failed to load model: \(model.name) - \(error.localizedDescription)")
                throw WhisperStateError.modelLoadFailed
            }
        }
        
        guard let whisperContext = whisperContext else {
            logger.error("Cannot transcribe: Model could not be loaded")
            throw WhisperStateError.modelLoadFailed
        }
        
        // Read audio data
        var data = try readAudioSamples(audioURL)
        
        // Set prompt
        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        await whisperContext.setPrompt(currentPrompt)
        
        // Check for cancellation before the heavy computation
        try Task.checkCancellation()
        
        // Transcribe with Swift cancellation handler bridging to Whisper abort
        let success = try await withTaskCancellationHandler {
            await whisperContext.fullTranscribe(samples: data)
        } onCancel: {
            // Use detached task with high priority to ensure immediate abort
            Task.detached(priority: .high) {
                await whisperContext.requestAbortNow()
            }
        }
        
        guard success else {
            logger.error("Core transcription engine failed (whisper_full).")
            throw WhisperStateError.whisperCoreFailed
        }
        
        var text = await whisperContext.getTranscription()

        logger.notice("✅ Local transcription completed successfully.")

        // Clear audio data from memory after transcription
        data.removeAll()

        // Only release resources if we created a new context (not using the shared one)
        if await whisperState?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return text
    }
    
    private func readAudioSamples(_ url: URL) throws -> [Float] {
        // Use AVAudioFile instead of raw data parsing to properly handle WAV files
        // This is more reliable than assuming a fixed 44-byte header
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            logger.error("Cannot open audio file for reading: \(url.lastPathComponent)")
            throw WhisperStateError.transcriptionFailed
        }

        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.error("Cannot create PCM buffer for audio file")
            throw WhisperStateError.transcriptionFailed
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            logger.error("Cannot read audio file into buffer: \(error)")
            throw WhisperStateError.transcriptionFailed
        }

        guard let channelData = buffer.floatChannelData else {
            logger.error("Cannot access float channel data from buffer")
            throw WhisperStateError.transcriptionFailed
        }

        let channelCount = Int(format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var samples: [Float] = []

        if channelCount == 1 {
            // Mono audio - direct copy
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        } else {
            // Multi-channel audio - mix down to mono
            samples.reserveCapacity(frameLength)
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples.append(sum / Float(channelCount))
            }
        }

        logger.debug("Read \(samples.count) audio samples from \(url.lastPathComponent)")
        return samples
    }
} 