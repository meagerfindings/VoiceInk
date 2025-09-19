#!/usr/bin/env swift

import Foundation
import SwiftData

// Simple script to help identify and remove problematic long-running transcriptions
print("VoiceInk Transcription Cleanup Utility")
print("=====================================")

// Define the Transcription model for this script
@Model
final class Transcription {
    var id: UUID
    var text: String
    var enhancedText: String?
    var timestamp: Date
    var duration: TimeInterval
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var source: String?
    var filename: String?
    
    init(text: String, duration: TimeInterval, enhancedText: String? = nil, audioFileURL: String? = nil, transcriptionModelName: String? = nil, aiEnhancementModelName: String? = nil, promptName: String? = nil, transcriptionDuration: TimeInterval? = nil, enhancementDuration: TimeInterval? = nil, source: String? = nil, filename: String? = nil) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.source = source
        self.filename = filename
    }
}

@MainActor 
func processTranscriptions() async throws {
    // Connect to VoiceInk's SwiftData store
    let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.mgreten.VoiceInk", isDirectory: true)
    let storeURL = appSupportURL.appendingPathComponent("default.store")
    
    let schema = Schema([Transcription.self])
    let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
    let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
    let context = container.mainContext
    
    // Fetch all transcriptions sorted by duration (longest first)
    let descriptor = FetchDescriptor<Transcription>(
        sortBy: [SortDescriptor(\.duration, order: .reverse)]
    )
    
    let transcriptions = try context.fetch(descriptor)
    
    print("Found \(transcriptions.count) total transcriptions")
    print("\nLongest duration transcriptions:")
    print("================================")
    
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    
    // Show the top 10 longest transcriptions
    let longTranscriptions = Array(transcriptions.prefix(10))
    
    for (index, transcription) in longTranscriptions.enumerated() {
        let durationHours = transcription.duration / 3600
        let source = transcription.source ?? "ui"
        let filename = transcription.filename ?? "N/A"
        let textPreview = String(transcription.text.prefix(50)) + (transcription.text.count > 50 ? "..." : "")
        
        print("\(index + 1). Duration: \(String(format: "%.2f", durationHours)) hours")
        print("   Source: \(source) | Filename: \(filename)")
        print("   Date: \(formatter.string(from: transcription.timestamp))")
        print("   Text: \(textPreview)")
        print("   ID: \(transcription.id)")
        print("")
    }
    
    // Ask if user wants to remove any transcriptions
    print("Enter the number of the transcription to remove (1-\(longTranscriptions.count)), or 'q' to quit:")
    
    if let input = readLine(), input != "q" {
        if let index = Int(input), index >= 1 && index <= longTranscriptions.count {
            let transcriptionToRemove = longTranscriptions[index - 1]
            
            // Confirm deletion
            print("Are you sure you want to remove this transcription? (y/N)")
            if let confirm = readLine(), confirm.lowercased() == "y" {
                context.delete(transcriptionToRemove)
                try context.save()
                print("Transcription removed successfully!")
                
                // Show updated stats
                let remainingTranscriptions = try context.fetch(FetchDescriptor<Transcription>())
                let totalDuration = remainingTranscriptions.reduce(0) { $0 + $1.duration }
                print("Updated stats: \(remainingTranscriptions.count) transcriptions, \(String(format: "%.2f", totalDuration / 3600)) total hours")
            } else {
                print("Deletion cancelled.")
            }
        } else {
            print("Invalid selection.")
        }
    }
}

// Call the main function
Task {
    do {
        await processTranscriptions()
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}