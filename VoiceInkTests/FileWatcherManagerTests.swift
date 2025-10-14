import Testing
import Foundation
import SwiftData
@testable import VoiceInk

@MainActor
struct FileWatcherManagerTests {
    
    @Test func testFileWatcherPairCreation() async throws {
        let inputPath = "/tmp/test_input"
        let outputPath = "/tmp/test_output"
        
        let pair = FileWatcherPair(inputFolderPath: inputPath, outputFolderPath: outputPath)
        
        #expect(pair.inputFolderPath == inputPath)
        #expect(pair.outputFolderPath == outputPath)
        #expect(pair.isEnabled == true)
        #expect(pair.inputFolderURL.path == inputPath)
        #expect(pair.outputFolderURL.path == outputPath)
    }
    
    @Test func testFileWatcherPairValidation() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        let validInputPath = tempDir.appendingPathComponent("valid_input_\(UUID().uuidString)").path
        let validOutputPath = tempDir.appendingPathComponent("valid_output_\(UUID().uuidString)").path
        let invalidPath = "/nonexistent/path/\(UUID().uuidString)"
        
        try fileManager.createDirectory(atPath: validInputPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: validOutputPath, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(atPath: validInputPath)
            try? fileManager.removeItem(atPath: validOutputPath)
        }
        
        let validPair = FileWatcherPair(inputFolderPath: validInputPath, outputFolderPath: validOutputPath)
        #expect(validPair.isValid == true)
        
        let invalidInputPair = FileWatcherPair(inputFolderPath: invalidPath, outputFolderPath: validOutputPath)
        #expect(invalidInputPair.isValid == false)
        
        let invalidOutputPair = FileWatcherPair(inputFolderPath: validInputPath, outputFolderPath: invalidPath)
        #expect(invalidOutputPair.isValid == false)
    }
    
    @Test func testSupportedMediaExtensions() async throws {
        let supportedURLs = [
            URL(fileURLWithPath: "/tmp/test.wav"),
            URL(fileURLWithPath: "/tmp/test.mp3"),
            URL(fileURLWithPath: "/tmp/test.m4a"),
            URL(fileURLWithPath: "/tmp/test.aiff"),
            URL(fileURLWithPath: "/tmp/test.mp4"),
            URL(fileURLWithPath: "/tmp/test.mov"),
            URL(fileURLWithPath: "/tmp/test.aac"),
            URL(fileURLWithPath: "/tmp/test.flac"),
            URL(fileURLWithPath: "/tmp/test.caf")
        ]
        
        for url in supportedURLs {
            #expect(SupportedMedia.isSupported(url: url) == true, "Expected \(url.pathExtension) to be supported")
        }
        
        let unsupportedURLs = [
            URL(fileURLWithPath: "/tmp/test.txt"),
            URL(fileURLWithPath: "/tmp/test.pdf"),
            URL(fileURLWithPath: "/tmp/test.doc"),
            URL(fileURLWithPath: "/tmp/test.jpg")
        ]
        
        for url in unsupportedURLs {
            #expect(SupportedMedia.isSupported(url: url) == false, "Expected \(url.pathExtension) to be unsupported")
        }
    }
    
    @Test func testFileWatcherManagerConfiguration() async throws {
        let manager = FileWatcherManager.shared
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let context = ModelContext(container)
        
        let whisperState = WhisperState(modelContext: context)
        
        manager.configure(modelContext: context, whisperState: whisperState)
        
        #expect(manager.isWatching == false)
        #expect(manager.processingFiles.isEmpty)
        #expect(manager.queuedFiles.isEmpty)
        #expect(manager.currentlyProcessingFile == nil)
    }
    
    @Test func testAddAndRemoveWatcherPair() async throws {
        let manager = FileWatcherManager.shared
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let context = ModelContext(container)
        let whisperState = WhisperState(modelContext: context)
        
        manager.configure(modelContext: context, whisperState: whisperState)
        
        let inputPath = tempDir.appendingPathComponent("input_\(UUID().uuidString)")
        let outputPath = tempDir.appendingPathComponent("output_\(UUID().uuidString)")
        
        try fileManager.createDirectory(at: inputPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputPath, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: inputPath)
            try? fileManager.removeItem(at: outputPath)
        }
        
        let initialCount = manager.watchedPairs.count
        
        manager.addWatcherPair(inputFolder: inputPath, outputFolder: outputPath)
        
        #expect(manager.watchedPairs.count == initialCount + 1)
        
        if let addedPair = manager.watchedPairs.last {
            #expect(addedPair.inputFolderPath == inputPath.path)
            #expect(addedPair.outputFolderPath == outputPath.path)
            #expect(addedPair.isEnabled == true)
            
            manager.removeWatcherPair(addedPair)
            #expect(manager.watchedPairs.count == initialCount)
        }
    }
    
    @Test func testTogglePairEnabled() async throws {
        let manager = FileWatcherManager.shared
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let context = ModelContext(container)
        let whisperState = WhisperState(modelContext: context)
        
        manager.configure(modelContext: context, whisperState: whisperState)
        
        let inputPath = tempDir.appendingPathComponent("input_\(UUID().uuidString)")
        let outputPath = tempDir.appendingPathComponent("output_\(UUID().uuidString)")
        
        try fileManager.createDirectory(at: inputPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputPath, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: inputPath)
            try? fileManager.removeItem(at: outputPath)
        }
        
        manager.addWatcherPair(inputFolder: inputPath, outputFolder: outputPath)
        
        guard let pair = manager.watchedPairs.last else {
            Issue.record("Failed to add watcher pair")
            return
        }
        
        #expect(pair.isEnabled == true)
        
        manager.togglePairEnabled(pair)
        #expect(pair.isEnabled == false)
        
        manager.togglePairEnabled(pair)
        #expect(pair.isEnabled == true)
        
        manager.removeWatcherPair(pair)
    }
    
    @Test func testStartStopWatching() async throws {
        let manager = FileWatcherManager.shared
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let context = ModelContext(container)
        let whisperState = WhisperState(modelContext: context)
        
        manager.configure(modelContext: context, whisperState: whisperState)
        
        let inputPath = tempDir.appendingPathComponent("input_\(UUID().uuidString)")
        let outputPath = tempDir.appendingPathComponent("output_\(UUID().uuidString)")
        
        try fileManager.createDirectory(at: inputPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputPath, withIntermediateDirectories: true)
        
        defer {
            manager.stopWatching()
            try? fileManager.removeItem(at: inputPath)
            try? fileManager.removeItem(at: outputPath)
        }
        
        manager.addWatcherPair(inputFolder: inputPath, outputFolder: outputPath)
        
        #expect(manager.isWatching == false)
        
        manager.startWatching()
        #expect(manager.isWatching == true)
        
        manager.stopWatching()
        #expect(manager.isWatching == false)
        #expect(manager.queuedFiles.isEmpty)
        #expect(manager.currentlyProcessingFile == nil)
    }
}
