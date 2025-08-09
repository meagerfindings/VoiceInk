import Foundation

// MARK: - Health Response Models

struct HealthResponse: Codable {
    let status: String
    let service: String
    let version: String
    let timestamp: TimeInterval
    let system: SystemInfo
    let api: APIInfo
    let transcription: TranscriptionInfo
    let capabilities: [String]
}

struct SystemInfo: Codable {
    let platform: String
    let osVersion: String
    let processorCount: Int
    let memoryUsageMB: Double
    let uptimeSeconds: TimeInterval
}

struct APIInfo: Codable {
    let endpoint: String
    let port: Int
    let isRunning: Bool
    let requestsServed: Int
    let averageProcessingTimeMs: Double
}

struct TranscriptionInfo: Codable {
    let currentModel: String?
    let modelLoaded: Bool
    let availableModels: [String]
    let enhancementEnabled: Bool
    let wordReplacementEnabled: Bool
}