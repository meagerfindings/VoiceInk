import Foundation

// MARK: - Diarization Result Models

/// Result from speaker diarization
struct DiarizationResult: Codable {
    let segments: [DiarizationSegment]
    let speakers: [String]
    let numSpeakers: Int
    let totalDuration: TimeInterval
    let method: DiarizationMethod
    let processingTime: TimeInterval?
}

/// Individual diarization segment with speaker information
struct DiarizationSegment: Codable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
    let confidence: Double?
    
    var duration: TimeInterval {
        return end - start
    }
}

/// Method used for diarization
enum DiarizationMethod: String, Codable {
    case stereo = "stereo"           // Stereo audio channel separation
    case tinydiarize = "tinydiarize" // whisper.cpp tinydiarize (speaker turns)
    case pyannote = "pyannote"       // pyannote.audio (if we add Python bridge)
    case none = "none"
}

/// Optimization mode for diarization
enum DiarizationMode: String, Codable {
    case fast = "fast"
    case balanced = "balanced"
    case accurate = "accurate"
}

// MARK: - Aligned Transcription Models

/// Transcription with speaker labels aligned
struct AlignedTranscription: Codable {
    let segments: [AlignedSegment]
    let speakers: [String]
    let text: String
    let textWithSpeakers: String
    let diarizationMethod: DiarizationMethod
}

/// Segment with both transcription and speaker information
struct AlignedSegment: Codable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String
    let confidence: Double?
    let speakerConfidence: Double?
    
    var duration: TimeInterval {
        return end - start
    }
}

// MARK: - API Request/Response Models

/// Parameters for diarization request
struct DiarizationParameters: Codable {
    let enableDiarization: Bool
    let diarizationMode: DiarizationMode?
    let minSpeakers: Int?
    let maxSpeakers: Int?
    let useTinydiarize: Bool
}

/// Enhanced transcription response with diarization
struct TranscriptionWithDiarizationResponse: Codable {
    let success: Bool
    let text: String
    let enhancedText: String?
    let segments: [AlignedSegment]?
    let speakers: [String]?
    let numSpeakers: Int?
    let textWithSpeakers: String?
    let metadata: TranscriptionWithDiarizationMetadata
}

struct TranscriptionWithDiarizationMetadata: Codable {
    let model: String
    let language: String
    let duration: Double
    let processingTime: Double
    let transcriptionTime: Double
    let diarizationTime: Double?
    let enhancementTime: Double?
    let enhanced: Bool
    let diarizationEnabled: Bool
    let diarizationMethod: DiarizationMethod?
    let replacementsApplied: Bool
}

// MARK: - Helper Extensions

extension DiarizationResult {
    /// Find the speaker at a given timestamp
    func speaker(at timestamp: TimeInterval) -> String? {
        for segment in segments {
            if timestamp >= segment.start && timestamp <= segment.end {
                return segment.speaker
            }
        }
        return nil
    }
    
    /// Get speaker segments for a specific speaker
    func segments(for speaker: String) -> [DiarizationSegment] {
        return segments.filter { $0.speaker == speaker }
    }
}

extension AlignedTranscription {
    /// Generate formatted text with speaker labels
    static func formatTextWithSpeakers(_ segments: [AlignedSegment]) -> String {
        var result = ""
        var currentSpeaker = ""
        
        for segment in segments {
            if segment.speaker != currentSpeaker {
                if !result.isEmpty {
                    result += "\n"
                }
                result += "\n[\(segment.speaker)]:\n"
                currentSpeaker = segment.speaker
            }
            result += segment.text + " "
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Generate simple inline speaker labels
    static func formatInlineWithSpeakers(_ segments: [AlignedSegment]) -> String {
        var result = ""
        var currentSpeaker = ""
        
        for segment in segments {
            if segment.speaker != currentSpeaker {
                result += " [\(segment.speaker)]: "
                currentSpeaker = segment.speaker
            }
            result += segment.text + " "
        }
        
        return result.trimmingCharacters(in: .whitespaces)
    }
}