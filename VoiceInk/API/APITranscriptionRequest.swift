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
    
    var isTerminal: Bool {
        return self == .completed || self == .failed || self == .cancelled
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
    
    // Auto-dismiss functionality
    @Published var terminalCompletedAt: Date? // When first entered terminal state
    @Published var autoDismissAt: Date? // Absolute deadline for auto-dismiss
    @Published var isUserInteracting: Bool = false // Pause auto-dismiss during interaction
    @Published var isPinned: Bool = false // User has pinned this item
    private var autoDismissRemainingSeconds: TimeInterval? // Cached when paused
    private var interactionReasons: Set<String> = [] // Track multiple interaction reasons

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
            let wasTerminal = self.status.isTerminal
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
            
            // Schedule auto-dismiss when first entering a terminal state
            if !wasTerminal && newStatus.isTerminal {
                self.markTerminal(status: newStatus)
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
            let wasTerminal = self.status.isTerminal
            
            self.errorMessage = message
            self.status = .failed
            self.processingInfo = "Failed: \(message)"
            self.completedAt = Date()
            
            // Schedule auto-dismiss when first entering failed state
            if !wasTerminal {
                self.markTerminal(status: .failed)
            }
        }
    }

    /// Mark as completed with result
    func setCompleted(result: Data, transcriptionText: String?) {
        DispatchQueue.main.async {
            let wasTerminal = self.status.isTerminal
            
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
            
            // Schedule auto-dismiss when first entering completed state
            if !wasTerminal {
                self.markTerminal(status: .completed)
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
    
    // MARK: - Auto-Dismiss Management
    
    /// Mark this request as entering a terminal state and schedule auto-dismiss
    /// Safe to call multiple times - will only set timestamp on first call
    func markTerminal(status: APITranscriptionStatus) {
        guard status.isTerminal else { return }
        
        Task { @MainActor in
            // Only set the terminal timestamp once
            if self.terminalCompletedAt == nil {
                self.terminalCompletedAt = Date()
                self.scheduleAutoDismiss()
            }
        }
    }
    
    /// Schedule auto-dismiss with AutoDismissManager
    @MainActor
    private func scheduleAutoDismiss() {
        guard !isPinned, let terminalTime = terminalCompletedAt else { return }
        
        let deadlineMs = (terminalTime.timeIntervalSince1970 + AutoDismissManager.autoDismissDelayMs / 1000.0) * 1000.0
        self.autoDismissAt = Date(timeIntervalSince1970: deadlineMs / 1000.0)
        
        AutoDismissManager.shared.register(
            id: self.id.uuidString,
            deadlineMs: deadlineMs
        ) { [weak self] in
            Task { @MainActor in
                self?.handleAutoDismiss()
            }
        }
    }
    
    /// Pause auto-dismiss due to user interaction
    func pauseAutoDismiss(reason: String) {
        DispatchQueue.main.async {
            let wasEmpty = self.interactionReasons.isEmpty
            self.interactionReasons.insert(reason)
            
            if wasEmpty && !self.interactionReasons.isEmpty {
                self.isUserInteracting = true
                
                Task { @MainActor in
                    AutoDismissManager.shared.pause(id: self.id.uuidString)
                }
            }
        }
    }
    
    /// Resume auto-dismiss when user interaction ends
    func resumeAutoDismiss(reason: String) {
        DispatchQueue.main.async {
            self.interactionReasons.remove(reason)
            
            if self.interactionReasons.isEmpty {
                self.isUserInteracting = false
                
                Task { @MainActor in
                    AutoDismissManager.shared.resume(id: self.id.uuidString)
                }
            }
        }
    }
    
    /// Clear all auto-dismiss state (called on manual removal or pin)
    func clearAutoDismiss() {
        DispatchQueue.main.async {
            self.terminalCompletedAt = nil
            self.autoDismissAt = nil
            self.isUserInteracting = false
            self.interactionReasons.removeAll()
            
            Task { @MainActor in
                AutoDismissManager.shared.unregister(id: self.id.uuidString)
            }
        }
    }
    
    /// Pin/unpin this item to prevent auto-dismiss
    func setPinned(_ pinned: Bool) {
        DispatchQueue.main.async {
            self.isPinned = pinned
            
            if pinned {
                self.clearAutoDismiss()
            } else if let status = APITranscriptionStatus(rawValue: self.status.rawValue),
                      status.isTerminal {
                // Re-schedule auto-dismiss if unpinned and in terminal state
                self.markTerminal(status: status)
            }
        }
    }
    
    /// Get remaining auto-dismiss time for UI display
    var remainingAutoDismissTime: TimeInterval? {
        guard !isPinned, let autoDismissAt = autoDismissAt else { return nil }
        
        if isUserInteracting {
            // When paused, compute from cached remaining time if available
            // We'll use the cached value instead of calling the manager
            let now = Date().timeIntervalSince1970 * 1000
            let elapsed = now - (terminalCompletedAt?.timeIntervalSince1970 ?? 0) * 1000
            return max(0, (AutoDismissManager.autoDismissDelayMs - elapsed) / 1000.0)
        } else {
            // When active, compute remaining time
            return max(0, autoDismissAt.timeIntervalSinceNow)
        }
    }
    
    /// Handle the actual auto-dismiss when timer fires
    private func handleAutoDismiss() {
        // Post notification for removal - this will be handled by TranscriptionAPIServer
        NotificationCenter.default.post(
            name: .apiTranscriptionAutoDismiss,
            object: nil,
            userInfo: ["requestId": self.id.uuidString, "reason": "auto_dismiss"]
        )
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

// MARK: - Notifications

extension Notification.Name {
    static let apiTranscriptionAutoDismiss = Notification.Name("apiTranscriptionAutoDismiss")
}
