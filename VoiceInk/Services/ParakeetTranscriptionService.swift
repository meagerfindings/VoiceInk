import Foundation
import CoreML
import AVFoundation
import FluidAudio
import os.log



class ParakeetTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private let customModelsDirectory: URL?
    @Published var isModelLoaded = false
    private let logger = Logger(subsystem: "com.voiceink.app", category: "ParakeetTranscriptionService")
    
    init(customModelsDirectory: URL? = nil) {
        self.customModelsDirectory = customModelsDirectory
    }

    func loadModel() async throws {
        if isModelLoaded {
            return
        }

        if let customModelsDirectory {
            do {
                asrManager = AsrManager(config: .default)
                let models = try await AsrModels.load(from: customModelsDirectory)
                try await asrManager?.initialize(models: models)
                isModelLoaded = true
            } catch {
                isModelLoaded = false
                asrManager = nil
            }
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        // Ensure model is loaded and asrManager is available (thread-safe)
        if asrManager == nil || !isModelLoaded {
            try await loadModel()
        }

        // Double-check after potential loading
		guard let asrManager = self.asrManager, isModelLoaded else {
			throw ASRError.notInitialized
		}
        
        let audioSamples = try readAudioSamples(from: audioURL)

        let durationSeconds = Double(audioSamples.count) / 16000.0

        let isVADEnabled = UserDefaults.standard.object(forKey: "IsVADEnabled") as? Bool ?? true

        let speechAudio: [Float]
        if durationSeconds < 20.0 || !isVADEnabled {
            speechAudio = audioSamples
        } else {
            let vadConfig = VadConfig(threshold: 0.7)
            if vadManager == nil, let customModelsDirectory {
                do {
                    vadManager = try await VadManager(
                        config: vadConfig,
                        modelDirectory: customModelsDirectory.deletingLastPathComponent()
                    )
                } catch {
                    // Silent failure
                }
            }

            do {
                if let vadManager {
                    let segments = try await vadManager.segmentSpeechAudio(audioSamples)
                    if segments.isEmpty {
                        speechAudio = audioSamples
                    } else {
                        speechAudio = segments.flatMap { $0 }
                    }
                } else {
                    speechAudio = audioSamples
                }
            } catch {
                speechAudio = audioSamples
            }
        }

        // Create a dedicated autorelease pool for the transcription to contain memory issues
        let text = try await withCheckedThrowingContinuation { continuation in
            Task.detached { [weak self] in
                do {
                    // Use autoreleasepool to ensure proper cleanup within the transcription
                    let result = try await asrManager.transcribe(speechAudio)
                    let extractedText = result.text

                    // Schedule cleanup immediately after getting the text
                    Task.detached { [weak self] in
                        // Brief delay to ensure result is fully processed
                        try? await Task.sleep(for: .milliseconds(50))
                        await MainActor.run {
                            asrManager.cleanup()
                            self?.isModelLoaded = false
                            self?.logger.notice("🦜 Parakeet ASR models cleaned up from memory")
                        }
                    }

                    continuation.resume(returning: extractedText)
                } catch {
                    // Clean up on error as well
                    Task.detached { [weak self] in
                        await MainActor.run {
                            asrManager.cleanup()
                            self?.isModelLoaded = false
                            self?.logger.notice("🦜 Parakeet ASR models cleaned up due to error")
                        }
                    }
                    continuation.resume(throwing: error)
                }
            }
        }

        return text
    }

    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            let data = try Data(contentsOf: url)
			guard data.count > 44 else {
				throw ASRError.invalidAudioData
			}

            let floats = stride(from: 44, to: data.count, by: 2).map {
                return data[$0..<$0 + 2].withUnsafeBytes {
                    let short = Int16(littleEndian: $0.load(as: Int16.self))
                    return max(-1.0, min(Float(short) / 32767.0, 1.0))
                }
            }
            
            return floats
		} catch {
			throw ASRError.invalidAudioData
		}
    }

}
