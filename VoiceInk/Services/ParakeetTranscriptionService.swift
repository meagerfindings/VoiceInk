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

        let result = try await asrManager.transcribe(speechAudio)
        let text = result.text

        // Cleanup after we've extracted the text to avoid use-after-free
        // Run cleanup on a separate task with proper error handling
        Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(100)) // Brief delay to ensure result is fully processed
            await MainActor.run {
                asrManager.cleanup()
                self?.isModelLoaded = false
                self?.logger.notice("🦜 Parakeet ASR models cleaned up from memory")
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
