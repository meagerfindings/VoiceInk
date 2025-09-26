import Foundation
import CoreML
import AVFoundation
import FluidAudio
import os.log



actor ParakeetTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private let customModelsDirectory: URL?
    var isModelLoaded = false
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

            var samples: [Float] = []
            var conversionError = false
            autoreleasepool {
            // Convert if necessary
            let floatBuffer: AVAudioPCMBuffer
            if needsConvert {
                // Create a fresh converter per chunk to avoid internal state confusion
                guard let chunkConverter = AVAudioConverter(from: readBuffer.format, to: targetFormat) else {
                    conversionError = true
                    return
                }
                // Estimate output capacity conservatively (add small headroom)
                let ratio = targetFormat.sampleRate / readBuffer.format.sampleRate
                let estOutFrames = AVAudioFrameCount(Double(readBuffer.frameLength) * ratio + 512)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estOutFrames) else {
                    conversionError = true
                    return
                }
                var provided = false
                var error: NSError?
                let status = chunkConverter.convert(to: outBuf, error: &error, withInputFrom: { _, outStatus in
                    if provided {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    provided = true
                    outStatus.pointee = .haveData
                    return readBuffer
                })
                if status == .error || error != nil { conversionError = true; return }
                
                floatBuffer = outBuf
            } else {
                floatBuffer = readBuffer
            }

            // Extract floats
            let n = Int(floatBuffer.frameLength)
            samples = [Float](repeating: 0, count: n)
            if let data = floatBuffer.floatChannelData {
                for i in 0..<n { samples[i] = data[0][i] }
            }
            }

            // Optional: simple VAD on chunk length threshold (skip for now for robustness)
            if conversionError || samples.isEmpty {
                self.logger.warning("Skipping chunk due to conversion issue or empty buffer at frame position \(currentFrame). error=\(conversionError) samples=\(samples.count)")
                currentFrame += AVAudioFramePosition(framesToRead)
                continue
            }
            let chunkText = try await transcribeSamplesOnce(asrManager: asrManager, samples: samples)
            if !chunkText.isEmpty {
                if !combinedText.isEmpty { combinedText.append(" ") }
                combinedText.append(chunkText)
            }

            currentFrame += AVAudioFramePosition(framesToRead)
        }

        // Cleanup after long job
        asrManager.cleanup()
        self.isModelLoaded = false
        self.logger.notice("🦜 Parakeet ASR models cleaned up after streaming")

        return combinedText
    }

    private func transcribeSamplesOnce(asrManager: AsrManager, samples: [Float]) async throws -> String {
        let result = try await asrManager.transcribe(samples)
        return result.text
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
