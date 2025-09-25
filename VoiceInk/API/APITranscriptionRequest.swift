import Foundation

/// Status of an API transcription request
enum APITranscriptionStatus: String, CaseIterable {
    case queued = "queued"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isActive: Bool {
        return self == .queued || self == .processing
    }
}

/// Model representing an API transcription request in the queue/processing system
class APITranscriptionRequest: ObservableObject, Identifiable {
    let id = UUID()
    let requestId: String
    let filename: String?
    let fileSize: Int
    let fileSizeMB: Double

    @Published var status: APITranscriptionStatus = .queued
    @Published var processingInfo: String = ""
    @Published var progress: Double = 0.0
    @Published var errorMessage: String?

    // Timing information
    let queuedAt: Date = Date()
    var startedAt: Date?
    var completedAt: Date?

    // Queue position tracking
    @Published var queuePosition: Int = 0
    @Published var estimatedWaitTime: TimeInterval = 0

    // Results
    var result: Data?
    var transcriptionText: String?

    init(requestId: String, filename: String?, fileSize: Int) {
        self.requestId = requestId
        self.filename = filename
        self.fileSize = fileSize
        self.fileSizeMB = Double(fileSize) / 1024 / 1024

        // Set initial processing info
        if let filename = filename {
            self.processingInfo = "Queued: \(filename) (\(String(format: "%.1f MB", fileSizeMB)))"
        } else {
            self.processingInfo = "Queued: \(String(format: "%.1f MB", fileSizeMB)) audio file"
        }
    }

    /// Update the request status
    func updateStatus(_ newStatus: APITranscriptionStatus, info: String? = nil) {
        DispatchQueue.main.async {
            self.status = newStatus

            if let info = info {
                self.processingInfo = info
            }

            switch newStatus {
            case .processing:
                self.startedAt = Date()
                self.progress = 0.1 // Indicate processing has started
            case .completed:
                self.completedAt = Date()
                self.progress = 1.0
            case .failed, .cancelled:
                self.completedAt = Date()
            case .queued:
                break // Keep existing info
            }
        }
    }

    /// Update processing progress and info
    func updateProgress(_ progress: Double, info: String? = nil) {
        DispatchQueue.main.async {
            self.progress = max(0.1, min(0.95, progress)) // Keep between 10% and 95% during processing
            if let info = info {
                self.processingInfo = info
            }
        }
    }

    /// Set error message and mark as failed
    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.status = .failed
            self.processingInfo = "Failed: \(message)"
            self.completedAt = Date()
        }
    }

    /// Mark as completed with result
    func setCompleted(result: Data, transcriptionText: String?) {
        DispatchQueue.main.async {
            self.result = result
            self.transcriptionText = transcriptionText
            self.status = .completed
            self.progress = 1.0
            self.completedAt = Date()

            if let filename = self.filename {
                self.processingInfo = "Completed: \(filename)"
            } else {
                self.processingInfo = "Transcription completed"
            }
        }
    }

    /// Calculate elapsed time since queued
    var elapsedTime: TimeInterval {
        return Date().timeIntervalSince(queuedAt)
    }

    /// Calculate processing time (if started)
    var processingTime: TimeInterval? {
        guard let startedAt = startedAt else { return nil }
        let endTime = completedAt ?? Date()
        return endTime.timeIntervalSince(startedAt)
    }

    /// Get displayable filename or fallback
    var displayFilename: String {
        return filename ?? "Audio File"
    }

    /// Get formatted file size string
    var formattedFileSize: String {
        return String(format: "%.1f MB", fileSizeMB)
    }

    /// Get formatted elapsed time
    var formattedElapsedTime: String {
        let elapsed = elapsedTime
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else {
            return "\(Int(elapsed / 60))m \(Int(elapsed.truncatingRemainder(dividingBy: 60)))s"
        }
    }

    /// Update queue position and estimated wait time
    func updateQueueInfo(position: Int, estimatedWait: TimeInterval) {
        DispatchQueue.main.async {
            self.queuePosition = position
            self.estimatedWaitTime = estimatedWait

            if self.status == .queued {
                let waitMinutes = estimatedWait / 60
                if waitMinutes < 1 {
                    self.processingInfo = "Position \(position) in queue (starting soon)"
                } else {
                    self.processingInfo = "Position \(position) in queue (~\(Int(waitMinutes))m wait)"
                }
            }
        }
    }
}

/// Extension for Equatable to allow comparison in arrays
extension APITranscriptionRequest: Equatable {
    static func == (lhs: APITranscriptionRequest, rhs: APITranscriptionRequest) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Extension for Hashable to allow use in Sets
extension APITranscriptionRequest: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}