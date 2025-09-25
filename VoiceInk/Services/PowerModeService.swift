import Foundation
import Combine
import IOKit
import IOKit.ps
import os

/// Service that monitors macOS power source changes (battery vs AC power)
/// Uses IOPowerSources to detect power state changes and publishes updates
@MainActor
class PowerModeService: ObservableObject {
    private let logger = Logger(subsystem: "com.voiceink.power", category: "PowerModeService")
    
    @Published var isOnBattery = false
    @Published var batteryPercent: Double = 0.0
    @Published var powerSourceDescription = "Unknown"
    
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    
    // MARK: - Public API
    
    /// Start monitoring power source changes
    func startMonitoring() {
        guard !isMonitoring else {
            logger.debug("Power monitoring already active")
            return
        }
        
        logger.info("Starting power source monitoring")
        
        // Set up power source notification
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        runLoopSource = IOPSNotificationCreateRunLoopSource({ (context) in
            guard let context = context else { return }
            let service = Unmanaged<PowerModeService>.fromOpaque(context).takeUnretainedValue()
            
            // Dispatch to main queue for thread safety
            DispatchQueue.main.async {
                service.refreshStatus()
            }
        }, context)?.takeRetainedValue()
        
        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
            isMonitoring = true
            
            // Get initial state immediately
            refreshStatus()
            
            logger.info("✅ Power monitoring started successfully")
        } else {
            logger.error("❌ Failed to create power source notification")
        }
    }
    
    /// Stop monitoring power source changes
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        logger.info("Stopping power source monitoring")
        
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
        
        isMonitoring = false
        logger.info("✅ Power monitoring stopped")
    }
    
    // MARK: - Private Implementation
    
    /// Refresh power source status by querying IOPowerSources
    private func refreshStatus() {
        // Get power source type (Battery or AC Power)
        let powerSourceType = IOPSGetProvidingPowerSourceType(nil)
        let powerSourceString = powerSourceType?.takeRetainedValue() as String? ?? "Unknown"
        
        let wasOnBattery = isOnBattery
        let newIsOnBattery = powerSourceString == "Battery Power"
        
        // Update published properties
        isOnBattery = newIsOnBattery
        powerSourceDescription = powerSourceString
        
        // Get detailed battery information
        updateBatteryDetails()
        
        // Log power source changes
        if wasOnBattery != newIsOnBattery {
            if newIsOnBattery {
                logger.info("🔋 Switched to battery power (\\(String(format: \"%.0f\", batteryPercent))%)")
            } else {
                logger.info("⚡ Switched to AC power")
            }
        } else {
            logger.debug("Power status refresh: \\(powerSourceString) (\\(String(format: \"%.0f\", batteryPercent))%)")
        }
    }
    
    /// Update battery percentage and detailed information
    private func updateBatteryDetails() {
        guard let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSourcesList = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFDictionary] else {
            batteryPercent = 0.0
            return
        }
        
        // Find the battery power source
        for powerSource in powerSourcesList {
            let powerSourceDict = powerSource as NSDictionary
            
            // Check if this is a battery
            if let transportType = powerSourceDict[kIOPSTransportTypeKey] as? String,
               transportType == kIOPSInternalType,
               let isPowerSource = powerSourceDict[kIOPSIsPresentKey] as? Bool,
               isPowerSource {
                
                // Get current and max capacity
                if let currentCapacity = powerSourceDict[kIOPSCurrentCapacityKey] as? Int,
                   let maxCapacity = powerSourceDict[kIOPSMaxCapacityKey] as? Int,
                   maxCapacity > 0 {
                    batteryPercent = Double(currentCapacity) / Double(maxCapacity) * 100.0
                } else {
                    batteryPercent = 0.0
                }
                
                logger.debug("Battery details updated: \\(String(format: \"%.1f\", batteryPercent))%")
                return
            }
        }
        
        // No battery found or no capacity info
        batteryPercent = isOnBattery ? 50.0 : 100.0 // Reasonable default
    }
    
    deinit {
        if isMonitoring, let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        }
    }
}