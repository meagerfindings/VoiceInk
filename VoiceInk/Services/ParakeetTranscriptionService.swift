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
        
        // Inspect audio duration to decide streaming vs single-shot
        let asset = AVURLAsset(url: audioURL)
        let durationSeconds = (try? await asset.load(.duration).seconds).map { Double($0) } ?? 0
        let useStreaming = durationSeconds > 180.0 // stream when longer than 3 minutes

        if !useStreaming {
            // Short clips: load once (existing path)
            let audioSamples = try readAudioSamples(from: audioURL)
            return try await transcribeSamplesOnce(asrManager: asrManager, samples: audioSamples)
        }

        // Long-form streaming transcription to bound memory
        let sr: Double = 16000.0
        let framesPerSecond = AVAudioFrameCount(sr)
        let chunkSeconds: Double = 120.0
        let framesPerChunk = AVAudioFrameCount(sr * chunkSeconds)

        guard let inputFile = try? AVAudioFile(forReading: audioURL) else {
            throw ASRError.invalidAudioData
        }

        // Convert to 16k mono float if needed
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let needsConvert = inputFile.fileFormat.sampleRate != sr || inputFile.fileFormat.channelCount != 1 || inputFile.fileFormat.commonFormat != .pcmFormatFloat32
        let converter = needsConvert ? AVAudioConverter(from: inputFile.fileFormat, to: targetFormat) : nil

        var combinedText = ""
        var currentFrame: AVAudioFramePosition = 0
        let totalFrames = inputFile.length

        while currentFrame < totalFrames {
            let remaining = totalFrames - currentFrame
            let framesToRead = min(AVAudioFrameCount(remaining), framesPerChunk)

            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: framesToRead) else {
                break
            }
            inputFile.framePosition = currentFrame
            try inputFile.read(into: readBuffer, frameCount: framesToRead)

            // Convert if necessary
            let floatBuffer: AVAudioPCMBuffer
            if let converter = converter {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(readBuffer.frameLength) * (sr / inputFile.fileFormat.sampleRate))) else {
                    break
                }
                var error: NSError?
                let status = converter.convert(to: outBuf, error: &error, withInputFrom: { _, outStatus in
                    outStatus.pointee = .haveData
                    return readBuffer
                })
                if status == .error { throw ASRError.invalidAudioData }
                floatBuffer = outBuf
            } else {
                floatBuffer = readBuffer
            }

            // Extract floats
            let n = Int(floatBuffer.frameLength)
            var samples = [Float](repeating: 0, count: n)
            if let data = floatBuffer.floatChannelData {
                for i in 0..<n { samples[i] = data[0][i] }
            }

            // Optional: simple VAD on chunk length threshold (skip for now for robustness)
            let chunkText = try await transcribeSamplesOnce(asrManager: asrManager, samples: samples)
            if !chunkText.isEmpty {
                if !combinedText.isEmpty { combinedText.append(" ") }
                combinedText.append(chunkText)
            }

            currentFrame += AVAudioFramePosition(framesToRead)
        }

        // Cleanup after long job
        await MainActor.run {
            asrManager.cleanup()
            self.isModelLoaded = false
            self.logger.notice("🦜 Parakeet ASR models cleaned up after streaming")
        }

        return combinedText
    }

    private func transcribeSamplesOnce(asrManager: AsrManager, samples: [Float]) async throws -> String {
        // Create a dedicated autorelease pool for the transcription to contain memory issues
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let result = try await asrManager.transcribe(samples)
                    continuation.resume(returning: result.text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
