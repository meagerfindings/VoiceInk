import Foundation
import AppKit
import OSLog

/// Manages auto-dismiss timers for API transcription requests using absolute timestamps
/// for background/visibilitychange resilience
@MainActor
class AutoDismissManager: ObservableObject {
    static let shared = AutoDismissManager()
    
    private let logger = Logger(subsystem: "com.voiceink.api", category: "AutoDismissManager")
    
    // Configuration
    static let autoDismissDelayMs: TimeInterval = 30_000 // 30 seconds
    
    // Tracked items with their absolute deadlines
    private var scheduledItems: [String: ScheduledItem] = [:]
    
    // Current active timer
    private var activeTimer: Timer?
    
    private init() {
        // Listen for app visibility changes to reconcile timers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVisibilityChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVisibilityChange),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        activeTimer?.invalidate()
    }
    
    // MARK: - Public API
    
    /// Register an item for auto-dismiss at the specified absolute deadline
    func register(id: String, deadlineMs: TimeInterval, onFire: @escaping () -> Void) {
        logger.debug("📅 Registering auto-dismiss for \(id) at \(deadlineMs)")
        
        scheduledItems[id] = ScheduledItem(
            id: id,
            deadlineMs: deadlineMs,
            onFire: onFire,
            isPaused: false
        )
        
        rescheduleTimer()
    }
    
    /// Unregister an item from auto-dismiss
    func unregister(id: String) {
        logger.debug("❌ Unregistering auto-dismiss for \(id)")
        
        scheduledItems.removeValue(forKey: id)
        rescheduleTimer()
    }
    
    /// Pause auto-dismiss for an item, storing remaining time
    func pause(id: String) {
        guard var item = scheduledItems[id] else { return }
        
        let now = Date().timeIntervalSince1970 * 1000
        item.remainingMs = max(0, item.deadlineMs - now)
        item.isPaused = true
        
        scheduledItems[id] = item
        logger.debug("⏸️ Paused auto-dismiss for \(id), remaining: \(item.remainingMs ?? 0)ms")
        
        rescheduleTimer()
    }
    
    /// Resume auto-dismiss for an item with a new deadline based on remaining time
    func resume(id: String) {
        guard var item = scheduledItems[id], item.isPaused else { return }
        
        let now = Date().timeIntervalSince1970 * 1000
        item.deadlineMs = now + (item.remainingMs ?? AutoDismissManager.autoDismissDelayMs)
        item.isPaused = false
        item.remainingMs = nil
        
        scheduledItems[id] = item
        logger.debug("▶️ Resumed auto-dismiss for \(id) at \(item.deadlineMs)")
        
        rescheduleTimer()
    }
    
    /// Update deadline for an existing item
    func updateDeadline(id: String, newDeadlineMs: TimeInterval) {
        guard var item = scheduledItems[id] else { return }
        
        item.deadlineMs = newDeadlineMs
        scheduledItems[id] = item
        
        logger.debug("🔄 Updated deadline for \(id) to \(newDeadlineMs)")
        rescheduleTimer()
    }
    
    /// Get remaining time for an item (for UI countdown display)
    func getRemainingTime(id: String) -> TimeInterval? {
        guard let item = scheduledItems[id] else { return nil }
        
        if item.isPaused {
            return (item.remainingMs ?? 0) / 1000.0
        } else {
            let now = Date().timeIntervalSince1970 * 1000
            let remaining = max(0, item.deadlineMs - now)
            return remaining / 1000.0
        }
    }
    
    // MARK: - Internal Timer Management
    
    /// Reschedule the single active timer for the next upcoming deadline
    private func rescheduleTimer() {
        activeTimer?.invalidate()
        activeTimer = nil
        
        let now = Date().timeIntervalSince1970 * 1000
        
        // Find the nearest non-paused deadline
        let nextDeadline = scheduledItems.values
            .filter { !$0.isPaused && $0.deadlineMs > now }
            .min { $0.deadlineMs < $1.deadlineMs }
        
        guard let next = nextDeadline else {
            logger.debug("⏱️ No upcoming deadlines, timer cleared")
            return
        }
        
        let delay = max(0.1, (next.deadlineMs - now) / 1000.0) // Convert to seconds, minimum 100ms
        
        logger.debug("⏱️ Scheduling timer for \(next.id) in \(delay)s")
        
        activeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.processDeadlines()
            }
        }
    }
    
    /// Process all overdue deadlines and fire their callbacks
    private func processDeadlines() {
        let now = Date().timeIntervalSince1970 * 1000
        
        let overdueItems = scheduledItems.values.filter { 
            !$0.isPaused && $0.deadlineMs <= now 
        }
        
        for item in overdueItems {
            logger.info("🔥 Auto-dismiss firing for \(item.id)")
            
            // Remove from scheduled items first to avoid re-entry
            scheduledItems.removeValue(forKey: item.id)
            
            // Fire the callback
            item.onFire()
        }
        
        // Reschedule for any remaining items
        if !overdueItems.isEmpty {
            rescheduleTimer()
        }
    }
    
    /// Handle app visibility changes to reconcile timers
    @objc private func handleVisibilityChange() {
        logger.debug("👁️ App visibility changed, reconciling timers")
        
        // Process any overdue items that may have been missed during backgrounding
        processDeadlines()
        
        // Reschedule timer for accuracy
        rescheduleTimer()
    }
}

// MARK: - Supporting Types

private struct ScheduledItem {
    let id: String
    var deadlineMs: TimeInterval
    let onFire: () -> Void
    var isPaused: Bool
    var remainingMs: TimeInterval? // Used when paused
}