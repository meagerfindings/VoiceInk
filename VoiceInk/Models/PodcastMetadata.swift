import Foundation

struct PodcastMetadata: Codable {
    let sourceType: String
    let flowType: FlowType
    let podcastName: String?
    let episodeGuid: String?
    let episodeTitle: String?
    let publishedDate: Date?
    let audioUrl: String?
    let audioPath: String?
    let durationSeconds: Int?
    let description: String?
    let downloadTimestamp: Date?
    
    enum FlowType: String, Codable {
        case aiAnalysis = "ai_analysis"
        case simple = "simple"
    }
    
    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case flowType = "flow_type"
        case podcastName = "podcast_name"
        case episodeGuid = "episode_guid"
        case episodeTitle = "episode_title"
        case publishedDate = "published_date"
        case audioUrl = "audio_url"
        case audioPath = "audio_path"
        case durationSeconds = "duration_seconds"
        case description
        case downloadTimestamp = "download_timestamp"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        sourceType = try container.decode(String.self, forKey: .sourceType)
        flowType = try container.decode(FlowType.self, forKey: .flowType)
        podcastName = try container.decodeIfPresent(String.self, forKey: .podcastName)
        episodeGuid = try container.decodeIfPresent(String.self, forKey: .episodeGuid)
        episodeTitle = try container.decodeIfPresent(String.self, forKey: .episodeTitle)
        audioUrl = try container.decodeIfPresent(String.self, forKey: .audioUrl)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let publishedDateString = try container.decodeIfPresent(String.self, forKey: .publishedDate) {
            publishedDate = iso8601Formatter.date(from: publishedDateString)
        } else {
            publishedDate = nil
        }
        
        if let downloadTimestampString = try container.decodeIfPresent(String.self, forKey: .downloadTimestamp) {
            downloadTimestamp = iso8601Formatter.date(from: downloadTimestampString)
        } else {
            downloadTimestamp = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(flowType, forKey: .flowType)
        try container.encodeIfPresent(podcastName, forKey: .podcastName)
        try container.encodeIfPresent(episodeGuid, forKey: .episodeGuid)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encodeIfPresent(audioUrl, forKey: .audioUrl)
        try container.encodeIfPresent(audioPath, forKey: .audioPath)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(description, forKey: .description)
        
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let publishedDate = publishedDate {
            try container.encode(iso8601Formatter.string(from: publishedDate), forKey: .publishedDate)
        }
        
        if let downloadTimestamp = downloadTimestamp {
            try container.encode(iso8601Formatter.string(from: downloadTimestamp), forKey: .downloadTimestamp)
        }
    }
    
    static func load(from url: URL) throws -> PodcastMetadata {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(PodcastMetadata.self, from: data)
    }
}
