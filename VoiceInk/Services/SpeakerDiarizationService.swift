import Foundation
import AVFoundation
import os

/// Service for speaker diarization using various methods
class SpeakerDiarizationService: ObservableObject {
    private let logger = Logger(subsystem: "com.voiceink", category: "Diarization")
    
    @Published var isProcessing = false
    @Published var lastError: String?
    
    init() {
        logger.info("Initializing Speaker Diarization Service")
    }
    
    /// Perform speaker diarization on audio file
    func diarize(
        audioURL: URL,
        mode: DiarizationMode = .balanced,
        minSpeakers: Int? = nil,
        maxSpeakers: Int? = nil,
        useTinydiarize: Bool = false
    ) async throws -> DiarizationResult {
        logger.info("Starting diarization for: \(audioURL.lastPathComponent)")
        let startTime = Date()
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Determine which method to use
        let method: DiarizationMethod
        if useTinydiarize {
            method = .tinydiarize
        } else if await checkIfStereoAudio(audioURL) {
            method = .stereo
        } else {
            // For mono audio, we'll need tinydiarize or external service
            method = .tinydiarize
        }
        
        logger.info("Using diarization method: \(method.rawValue)")
        
        var result: DiarizationResult
        
        switch method {
        case .stereo:
            result = try await diarizeStereoAudio(audioURL: audioURL)
        case .tinydiarize:
            result = try await diarizeTinydiarize(audioURL: audioURL, mode: mode)
        case .pyannote:
            // Future: Python bridge to pyannote
            throw DiarizationError.methodNotImplemented("pyannote")
        case .none:
            throw DiarizationError.noDiarizationAvailable
        }
        
        // Add processing time
        let processingTime = Date().timeIntervalSince(startTime)
        result = DiarizationResult(
            segments: result.segments,
            speakers: result.speakers,
            numSpeakers: result.numSpeakers,
            totalDuration: result.totalDuration,
            method: result.method,
            processingTime: processingTime
        )
        
        logger.info("Diarization completed in \(String(format: "%.2f", processingTime))s: \(result.numSpeakers) speakers, \(result.segments.count) segments")
        
        return result
    }
    
    /// Check if audio file has stereo channels
    private func checkIfStereoAudio(_ audioURL: URL) async -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: audioURL)
            let channelCount = audioFile.fileFormat.channelCount
            logger.debug("Audio file has \(channelCount) channels")
            return channelCount >= 2
        } catch {
            logger.error("Failed to check audio channels: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Diarize stereo audio by channel separation
    private func diarizeStereoAudio(audioURL: URL) async throws -> DiarizationResult {
        logger.info("Performing stereo channel diarization")
        
        // This is a simplified approach
        // In stereo recordings, often left channel = one speaker, right channel = another
        
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        
        // For stereo diarization, we analyze channel energy/activity
        // This is a placeholder - full implementation would analyze audio channels
        
        let segments: [DiarizationSegment] = [
            DiarizationSegment(
                start: 0,
                end: duration,
                speaker: "SPEAKER_00",
                confidence: 0.8
            )
        ]
        
        return DiarizationResult(
            segments: segments,
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            numSpeakers: 2,
            totalDuration: duration,
            method: .stereo,
            processingTime: nil
        )
    }
    
    /// Diarize using whisper.cpp's tinydiarize feature
    private func diarizeTinydiarize(audioURL: URL, mode: DiarizationMode) async throws -> DiarizationResult {
        logger.info("Performing tinydiarize diarization")
        
        // Note: This requires whisper.cpp to be called with tdrz_enable flag
        // and a model that supports tinydiarize (special tdrz models)
        
        // For now, return a placeholder result
        // Full implementation would integrate with LocalTranscriptionService
        // to run whisper with tinydiarize enabled
        
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        
        // Placeholder segments
        let segments: [DiarizationSegment] = []
        
        return DiarizationResult(
            segments: segments,
            speakers: [],
            numSpeakers: 0,
            totalDuration: duration,
            method: .tinydiarize,
            processingTime: nil
        )
    }
    
    /// Align transcription with diarization results
    func alignTranscriptionWithDiarization(
        transcription: String,
        timestamps: [(start: TimeInterval, end: TimeInterval, text: String)],
        diarization: DiarizationResult
    ) -> AlignedTranscription {
        logger.info("Aligning transcription with diarization")
        
        var alignedSegments: [AlignedSegment] = []
        
        for (start, end, text) in timestamps {
            // Find the best matching speaker for this time range
            let speaker = findBestSpeaker(
                start: start,
                end: end,
                diarizationSegments: diarization.segments
            )
            
            let alignedSegment = AlignedSegment(
                start: start,
                end: end,
                text: text,
                speaker: speaker.speaker,
                confidence: nil,
                speakerConfidence: speaker.confidence
            )
            
            alignedSegments.append(alignedSegment)
        }
        
        // Merge consecutive segments from same speaker
        alignedSegments = mergeConsecutiveSameSpeaker(alignedSegments)
        
        // Get unique speakers
        let speakers = Array(Set(alignedSegments.map { $0.speaker })).sorted()
        
        // Generate formatted text
        let textWithSpeakers = AlignedTranscription.formatTextWithSpeakers(alignedSegments)
        
        return AlignedTranscription(
            segments: alignedSegments,
            speakers: speakers,
            text: transcription,
            textWithSpeakers: textWithSpeakers,
            diarizationMethod: diarization.method
        )
    }
    
    /// Find the best matching speaker for a time range
    private func findBestSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> (speaker: String, confidence: Double) {
        var bestSpeaker = "SPEAKER_UNKNOWN"
        var bestOverlap: TimeInterval = 0
        var bestConfidence: Double = 0
        
        for segment in diarizationSegments {
            // Calculate overlap
            let overlapStart = max(start, segment.start)
            let overlapEnd = min(end, segment.end)
            
            if overlapStart < overlapEnd {
                let overlap = overlapEnd - overlapStart
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = segment.speaker
                    
                    // Calculate confidence based on overlap ratio
                    let totalDuration = end - start
                    bestConfidence = totalDuration > 0 ? overlap / totalDuration : 0
                }
            }
        }
        
        return (bestSpeaker, bestConfidence)
    }
    
    /// Merge consecutive segments from the same speaker
    private func mergeConsecutiveSameSpeaker(_ segments: [AlignedSegment]) -> [AlignedSegment] {
        guard !segments.isEmpty else { return [] }
        
        var merged: [AlignedSegment] = []
        var currentSegment = segments[0]
        
        for i in 1..<segments.count {
            let segment = segments[i]
            
            // Check if same speaker and close in time (within 1 second)
            if segment.speaker == currentSegment.speaker &&
               segment.start - currentSegment.end < 1.0 {
                // Merge segments
                currentSegment = AlignedSegment(
                    start: currentSegment.start,
                    end: segment.end,
                    text: currentSegment.text + " " + segment.text,
                    speaker: currentSegment.speaker,
                    confidence: min(currentSegment.confidence ?? 1.0, segment.confidence ?? 1.0),
                    speakerConfidence: min(
                        currentSegment.speakerConfidence ?? 1.0,
                        segment.speakerConfidence ?? 1.0
                    )
                )
            } else {
                // Different speaker or too far apart
                merged.append(currentSegment)
                currentSegment = segment
            }
        }
        
        // Add the last segment
        merged.append(currentSegment)
        
        return merged
    }
}

// MARK: - Diarization Errors

enum DiarizationError: LocalizedError {
    case methodNotImplemented(String)
    case noDiarizationAvailable
    case audioProcessingFailed(String)
    case invalidAudioFormat
    
    var errorDescription: String? {
        switch self {
        case .methodNotImplemented(let method):
            return "Diarization method '\(method)' is not yet implemented"
        case .noDiarizationAvailable:
            return "No suitable diarization method available for this audio"
        case .audioProcessingFailed(let message):
            return "Audio processing failed: \(message)"
        case .invalidAudioFormat:
            return "Invalid audio format for diarization"
        }
    }
}