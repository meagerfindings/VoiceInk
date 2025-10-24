import Foundation

struct TranscriptionOutput: Codable {
    let text: String
    let title: String?
    let metadata: TranscriptionMetadata
    
    struct TranscriptionMetadata: Codable {
        let sourceType: String
        let flowType: FlowType?
        let podcastName: String?
        let videoId: String?
        let videoUrl: String?
        let transcriptionSource: String
        let transcribedAt: Date
        let audioFilePath: String?
        let durationSeconds: Int?
        let confidenceScore: Double?
        let language: String?
        
        enum FlowType: String, Codable {
            case aiAnalysis = "ai_analysis"
            case simple = "simple"
        }
        
        enum CodingKeys: String, CodingKey {
            case sourceType = "source_type"
            case flowType = "flow_type"
            case podcastName = "podcast_name"
            case videoId = "video_id"
            case videoUrl = "video_url"
            case transcriptionSource = "transcription_source"
            case transcribedAt = "transcribed_at"
            case audioFilePath = "audio_file_path"
            case durationSeconds = "duration_seconds"
            case confidenceScore = "confidence_score"
            case language
        }
        
        init(
            sourceType: String = "audio_transcription",
            flowType: FlowType? = nil,
            podcastName: String? = nil,
            videoId: String? = nil,
            videoUrl: String? = nil,
            transcriptionSource: String = "voiceink",
            transcribedAt: Date = Date(),
            audioFilePath: String? = nil,
            durationSeconds: Int? = nil,
            confidenceScore: Double? = nil,
            language: String? = nil
        ) {
            self.sourceType = sourceType
            self.flowType = flowType
            self.podcastName = podcastName
            self.videoId = videoId
            self.videoUrl = videoUrl
            self.transcriptionSource = transcriptionSource
            self.transcribedAt = transcribedAt
            self.audioFilePath = audioFilePath
            self.durationSeconds = durationSeconds
            self.confidenceScore = confidenceScore
            self.language = language
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            sourceType = try container.decode(String.self, forKey: .sourceType)
            flowType = try container.decodeIfPresent(FlowType.self, forKey: .flowType)
            podcastName = try container.decodeIfPresent(String.self, forKey: .podcastName)
            videoId = try container.decodeIfPresent(String.self, forKey: .videoId)
            videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
            transcriptionSource = try container.decode(String.self, forKey: .transcriptionSource)
            audioFilePath = try container.decodeIfPresent(String.self, forKey: .audioFilePath)
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            confidenceScore = try container.decodeIfPresent(Double.self, forKey: .confidenceScore)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            let transcribedAtString = try container.decode(String.self, forKey: .transcribedAt)
            if let date = iso8601Formatter.date(from: transcribedAtString) {
                transcribedAt = date
            } else {
                transcribedAt = Date()
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            
            try container.encode(sourceType, forKey: .sourceType)
            try container.encodeIfPresent(flowType, forKey: .flowType)
            try container.encodeIfPresent(podcastName, forKey: .podcastName)
            try container.encodeIfPresent(videoId, forKey: .videoId)
            try container.encodeIfPresent(videoUrl, forKey: .videoUrl)
            try container.encode(transcriptionSource, forKey: .transcriptionSource)
            try container.encodeIfPresent(audioFilePath, forKey: .audioFilePath)
            try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
            try container.encodeIfPresent(confidenceScore, forKey: .confidenceScore)
            try container.encodeIfPresent(language, forKey: .language)
            
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(iso8601Formatter.string(from: transcribedAt), forKey: .transcribedAt)
        }
    }
    
    init(text: String, title: String? = nil, metadata: TranscriptionMetadata) {
        self.text = text
        self.title = title
        self.metadata = metadata
    }
    
    static func forPodcast(
        transcription: String,
        podcastMetadata: PodcastMetadata,
        audioFilePath: String? = nil,
        confidenceScore: Double? = nil,
        language: String? = nil
    ) -> TranscriptionOutput {
        let flowType: TranscriptionMetadata.FlowType? = switch podcastMetadata.flowType {
        case .aiAnalysis: .aiAnalysis
        case .simple: .simple
        }
        
        let metadata = TranscriptionMetadata(
            flowType: flowType,
            podcastName: podcastMetadata.podcastName,
            audioFilePath: audioFilePath,
            durationSeconds: podcastMetadata.durationSeconds,
            confidenceScore: confidenceScore,
            language: language
        )
        
        return TranscriptionOutput(
            text: transcription,
            title: podcastMetadata.episodeTitle,
            metadata: metadata
        )
    }
    
    static func forYouTube(
        transcription: String,
        videoId: String,
        audioFilePath: String? = nil,
        durationSeconds: Int? = nil,
        confidenceScore: Double? = nil,
        language: String? = nil,
        flowType: TranscriptionMetadata.FlowType? = nil
    ) -> TranscriptionOutput {
        let videoUrl = "https://www.youtube.com/watch?v=\(videoId)"
        
        let metadata = TranscriptionMetadata(
            flowType: flowType,
            videoId: videoId,
            videoUrl: videoUrl,
            audioFilePath: audioFilePath,
            durationSeconds: durationSeconds,
            confidenceScore: confidenceScore,
            language: language
        )
        
        return TranscriptionOutput(
            text: transcription,
            title: nil,
            metadata: metadata
        )
    }
    
    static func extractYouTubeVideoId(from filename: String) -> String? {
        let basename = (filename as NSString).lastPathComponent
        let nameWithoutExtension = (basename as NSString).deletingPathExtension
        
        let youtubeIdPattern = "^([a-zA-Z0-9_-]{11})$"
        if let regex = try? NSRegularExpression(pattern: youtubeIdPattern) {
            let range = NSRange(nameWithoutExtension.startIndex..., in: nameWithoutExtension)
            if regex.firstMatch(in: nameWithoutExtension, range: range) != nil {
                return nameWithoutExtension
            }
        }
        
        return nil
    }
    
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
