import Foundation
import Cocoa
import ScreenCaptureKit

@MainActor
class ScreenRecordingHelper: ObservableObject {
    @Published var hasPermission = false
    @Published var isCheckingPermission = false
    @Published var lastCheckTime = Date()
    
    init() {
        checkPermission()
    }
    
    /// Check screen recording permission using multiple methods
    func checkPermission() {
        isCheckingPermission = true
        
        // Method 1: Try ScreenCaptureKit first for most reliable check
        Task {
            do {
                // Try to get available content - this will fail if no permission
                let content = try await SCShareableContent.current
                // If we can get content and it has displays, we have permission
                let hasAccess = !content.displays.isEmpty
                
                await MainActor.run {
                    self.hasPermission = hasAccess
                    self.isCheckingPermission = false
                    print("🔍 Screen Recording Permission Check: \(hasAccess ? "✅ GRANTED" : "❌ DENIED") (via ScreenCaptureKit)")
                }
            } catch {
                // Method 2: If SCShareableContent fails, try CGWindowListCopyWindowInfo
                // This is more reliable than CGPreflightScreenCaptureAccess on newer macOS
                let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
                let canSeeWindowNames = windowList?.contains { dict in
                    // Check if we can see window names (requires screen recording permission)
                    if let ownerName = dict[kCGWindowOwnerName as String] as? String,
                       let windowName = dict[kCGWindowName as String] as? String {
                        return !ownerName.isEmpty && !windowName.isEmpty
                    }
                    return false
                } ?? false
                
                // Method 3: Fall back to CGPreflightScreenCaptureAccess as last resort
                let cgAccess = CGPreflightScreenCaptureAccess()
                
                // Use the most optimistic result
                let hasAccess = canSeeWindowNames || cgAccess
                
                await MainActor.run {
                    self.hasPermission = hasAccess
                    self.isCheckingPermission = false
                    print("🔍 Screen Recording Permission Check: \(hasAccess ? "✅ GRANTED" : "❌ DENIED") (windowNames: \(canSeeWindowNames), cgAccess: \(cgAccess))")
                }
            }
            
            lastCheckTime = Date()
        }
    }
    
    /// Request screen recording permission with improved handling
    func requestPermission() {
        // First, try the standard request
        CGRequestScreenCaptureAccess()
        
        // Give it a moment to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Open System Settings to the correct pane
            self?.openSystemSettings()
        }
    }
    
    /// Open System Settings to Privacy & Security > Screen Recording
    func openSystemSettings() {
        // Try multiple URLs for different macOS versions
        let urls = [
            // macOS 13+ Ventura and newer
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            // Alternative format
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            // Fallback to general privacy settings
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        
        for urlString in urls {
            if let url = URL(string: urlString) {
                if NSWorkspace.shared.open(url) {
                    break
                }
            }
        }
    }
    
    /// Reset and retry permission check
    func resetPermissionCheck() {
        // Try to trigger a fresh permission check
        Task {
            // Method 1: Try creating a minimal screen capture
            if #available(macOS 12.3, *) {
                do {
                    let content = try await SCShareableContent.current
                    if let display = content.displays.first {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = 1
                        config.height = 1
                        
                        // This will trigger permission dialog if needed
                        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                        try await stream.addStreamOutput(DummyStreamOutput(), type: .screen, sampleHandlerQueue: nil)
                        
                        // Immediately stop the stream
                        try await stream.stopCapture()
                        
                        await MainActor.run {
                            self.hasPermission = true
                        }
                    }
                } catch {
                    // Permission likely denied or not granted yet
                    await MainActor.run {
                        self.hasPermission = false
                    }
                }
            }
            
            // Re-check permission after attempt
            checkPermission()
        }
    }
    
    /// Get detailed permission status message
    func getStatusMessage() -> String {
        if isCheckingPermission {
            return "Checking screen recording permission..."
        }
        
        if hasPermission {
            return "Screen recording permission is granted ✓"
        }
        
        return """
        Screen recording permission is not granted.
        
        To fix this:
        1. Click 'Open System Settings' below
        2. Find VoiceInk in the list
        3. Toggle the switch ON
        4. You may need to restart VoiceInk
        """
    }
}

// Dummy stream output for permission testing
@available(macOS 12.3, *)
private class DummyStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Do nothing - this is just for permission testing
    }
}