import SwiftUI
import AVFoundation
import Cocoa
import KeyboardShortcuts
import Combine

@MainActor
class PermissionManager: ObservableObject {
    @Published var audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var isAccessibilityEnabled = false
    @Published var isScreenRecordingEnabled = false
    @Published var isKeyboardShortcutSet = false
    
    let screenRecordingHelper = ScreenRecordingHelper()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Start observing system events that might indicate permission changes
        setupNotificationObservers()
        
        // Observe screen recording permission changes
        screenRecordingHelper.$hasPermission
            .sink { [weak self] hasPermission in
                self?.isScreenRecordingEnabled = hasPermission
            }
            .store(in: &cancellables)
        
        // Initial permission checks
        checkAllPermissions()
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupNotificationObservers() {
        // Only observe when app becomes active, as this is a likely time for permissions to have changed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func applicationDidBecomeActive() {
        checkAllPermissions()
    }
    
    func checkAllPermissions() {
        checkAccessibilityPermissions()
        checkScreenRecordingPermission()
        checkAudioPermissionStatus()
        checkKeyboardShortcut()
    }
    
    func checkAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.async {
            self.isAccessibilityEnabled = accessibilityEnabled
        }
    }
    
    func checkScreenRecordingPermission() {
        screenRecordingHelper.checkPermission()
    }
    
    func requestScreenRecordingPermission() {
        screenRecordingHelper.requestPermission()
    }
    
    func resetScreenRecordingPermission() {
        screenRecordingHelper.resetPermissionCheck()
    }
    
    func checkAudioPermissionStatus() {
        DispatchQueue.main.async {
            self.audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }
    
    func requestAudioPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.audioPermissionStatus = granted ? .authorized : .denied
            }
        }
    }
    
    func checkKeyboardShortcut() {
        DispatchQueue.main.async {
            self.isKeyboardShortcutSet = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil
        }
    }
}

struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let buttonTitle: String
    let buttonAction: () -> Void
    let checkPermission: () -> Void
    @State private var isRefreshing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                // Icon with background
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: isGranted ? "\(icon).fill" : icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(isGranted ? .green : .orange)
                        .symbolRenderingMode(.hierarchical)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status indicator with refresh
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            isRefreshing = true
                        }
                        checkPermission()
                        
                        // Reset the animation after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isRefreshing = false
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    
                    if isGranted {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                            .symbolRenderingMode(.hierarchical)
                    } else {
                        Image(systemName: "xmark.seal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            
            if !isGranted {
                Button(action: buttonAction) {
                    HStack {
                        Text(buttonTitle)
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(CardBackground(isSelected: false))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    @StateObject private var permissionManager = PermissionManager()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 24) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                        .padding(20)
                        .background(Circle()
                            .fill(Color(.windowBackgroundColor).opacity(0.9))
                            .shadow(color: .black.opacity(0.1), radius: 10, y: 5))
                    
                    VStack(spacing: 8) {
                        Text("App Permissions")
                            .font(.system(size: 28, weight: .bold))
                        Text("VoiceInk requires the following permissions to function properly")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                
                // Permission Cards
                VStack(spacing: 16) {
                    // Keyboard Shortcut Permission
                    PermissionCard(
                        icon: "keyboard",
                        title: "Keyboard Shortcut",
                        description: "Set up a keyboard shortcut to use VoiceInk anywhere",
                        isGranted: hotkeyManager.selectedHotkey1 != .none,
                        buttonTitle: "Configure Shortcut",
                        buttonAction: {
                            NotificationCenter.default.post(
                                name: .navigateToDestination,
                                object: nil,
                                userInfo: ["destination": "Settings"]
                            )
                        },
                        checkPermission: { permissionManager.checkKeyboardShortcut() }
                    )
                    
                    // Audio Permission
                    PermissionCard(
                        icon: "mic",
                        title: "Microphone Access",
                        description: "Allow VoiceInk to record your voice for transcription",
                        isGranted: permissionManager.audioPermissionStatus == .authorized,
                        buttonTitle: permissionManager.audioPermissionStatus == .notDetermined ? "Request Permission" : "Open System Settings",
                        buttonAction: {
                            if permissionManager.audioPermissionStatus == .notDetermined {
                                permissionManager.requestAudioPermission()
                            } else {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        },
                        checkPermission: { permissionManager.checkAudioPermissionStatus() }
                    )
                    
                    // Accessibility Permission
                    PermissionCard(
                        icon: "hand.raised",
                        title: "Accessibility Access",
                        description: "Allow VoiceInk to paste transcribed text directly at your cursor position",
                        isGranted: permissionManager.isAccessibilityEnabled,
                        buttonTitle: "Open System Settings",
                        buttonAction: {
                            // First prompt for accessibility permission
                            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                            AXIsProcessTrustedWithOptions(options)
                            
                            // Then open system preferences as backup
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        },
                        checkPermission: { permissionManager.checkAccessibilityPermissions() }
                    )
                    
                    // Screen Recording Permission
                    VStack(alignment: .leading, spacing: 8) {
                        PermissionCard(
                            icon: "rectangle.on.rectangle",
                            title: "Screen Recording Access",
                            description: "Allow VoiceInk to understand context from your screen for transcript Enhancement",
                            isGranted: permissionManager.isScreenRecordingEnabled,
                            buttonTitle: permissionManager.isScreenRecordingEnabled ? "Permission Granted" : "Open System Settings",
                            buttonAction: {
                                if !permissionManager.isScreenRecordingEnabled {
                                    // Open system settings directly since permission is already granted
                                    permissionManager.screenRecordingHelper.openSystemSettings()
                                    
                                    // Schedule a re-check after user might have changed settings
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        permissionManager.checkScreenRecordingPermission()
                                    }
                                }
                            },
                            checkPermission: { 
                                permissionManager.checkScreenRecordingPermission()
                                // Double-check after a short delay in case of async permission updates
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    permissionManager.checkScreenRecordingPermission()
                                }
                            }
                        )
                        
                        // Add troubleshooting buttons
                        if !permissionManager.isScreenRecordingEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Button("Force Refresh") {
                                        // Force multiple checks with delays
                                        permissionManager.resetScreenRecordingPermission()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            permissionManager.checkScreenRecordingPermission()
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                            permissionManager.checkScreenRecordingPermission()
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    
                                    Button("System Settings") {
                                        permissionManager.screenRecordingHelper.openSystemSettings()
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                                .padding(.leading, 40)
                                
                                Text("Troubleshooting: Click 'Force Refresh' after granting permission in System Settings. If still not working, restart VoiceInk.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            permissionManager.checkAllPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check permissions when app becomes active
            permissionManager.checkAllPermissions()
        }
    }
}

#Preview {
    PermissionsView()
} 
