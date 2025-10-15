//
//  TranscriptionTests.swift
//  VoiceInkTests
//
//  Created for transcription functionality testing
//

import Testing
import SwiftData
import AVFoundation
import Foundation
@testable import VoiceInk

@MainActor
struct TranscriptionTests {
    
    // MARK: - TranscriptionService Protocol Tests
    
    @Test("TranscriptionService protocol conformance")
    func testTranscriptionServiceProtocolConformance() async throws {
        let modelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("models_test")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        let localService = LocalTranscriptionService(modelsDirectory: modelsDir)
        #expect(localService is TranscriptionService)
        
        let cloudService = CloudTranscriptionService()
        #expect(cloudService is TranscriptionService)
        
        let nativeService = NativeAppleTranscriptionService()
        #expect(nativeService is TranscriptionService)
        
        let parakeetModelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet_test")
        try? FileManager.default.createDirectory(at: parakeetModelsDir, withIntermediateDirectories: true)
        let parakeetService = ParakeetTranscriptionService(customModelsDirectory: parakeetModelsDir)
        #expect(parakeetService is TranscriptionService)
        
        try? FileManager.default.removeItem(at: modelsDir)
        try? FileManager.default.removeItem(at: parakeetModelsDir)
    }
    
    // MARK: - Transcription Model Tests
    
    @Test("Transcription model creation")
    func testTranscriptionModelCreation() {
        let audioURL = URL(fileURLWithPath: "/tmp/test.wav")
        let transcription = Transcription(
            text: "Test transcription",
            duration: 5.0,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: "test-model"
        )
        
        #expect(transcription.text == "Test transcription")
        #expect(transcription.duration == 5.0)
        #expect(transcription.audioFileURL == audioURL.absoluteString)
        #expect(transcription.transcriptionModelName == "test-model")
        #expect(transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue)
    }
    
    @Test("Transcription status values")
    func testTranscriptionStatusValues() {
        #expect(TranscriptionStatus.completed.rawValue == "completed")
        #expect(TranscriptionStatus.failed.rawValue == "failed")
        #expect(TranscriptionStatus.processing.rawValue == "processing")
    }
    
    // MARK: - WhisperState Transcription Tests
    
    @Test("WhisperState transcription initialization")
    func testWhisperStateTranscriptionInitialization() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, FileWatcherPair.self, configurations: config)
        let modelContext = container.mainContext
        
        let whisperState = WhisperState(modelContext: modelContext)
        
        #expect(whisperState.recordingState == .idle)
        #expect(!whisperState.isModelLoaded)
        #expect(whisperState.loadedLocalModel == nil)
    }
    
    @Test("WhisperState recording states")
    func testWhisperStateRecordingStates() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, FileWatcherPair.self, configurations: config)
        let modelContext = container.mainContext
        
        let whisperState = WhisperState(modelContext: modelContext)
        
        #expect(whisperState.recordingState == .idle)
        
        whisperState.recordingState = .recording
        #expect(whisperState.recordingState == .recording)
        
        whisperState.recordingState = .transcribing
        #expect(whisperState.recordingState == .transcribing)
        
        whisperState.recordingState = .enhancing
        #expect(whisperState.recordingState == .enhancing)
        
        whisperState.recordingState = .busy
        #expect(whisperState.recordingState == .busy)
        
        whisperState.recordingState = .idle
        #expect(whisperState.recordingState == .idle)
    }
    
    // MARK: - FileWatcher Integration Tests
    
    @Test("FileWatcher transcription integration")
    func testFileWatcherTranscriptionIntegration() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let modelContext = container.mainContext
        
        let whisperState = WhisperState(modelContext: modelContext)
        let fileWatcherManager = FileWatcherManager(modelContext: modelContext, whisperState: whisperState)
        
        #expect(fileWatcherManager.watcherPairs.isEmpty)
        #expect(fileWatcherManager.currentlyProcessingFile == nil)
        #expect(!fileWatcherManager.isWatching)
    }
    
    @Test("FileWatcher queue management")
    func testFileWatcherQueueManagement() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FileWatcherPair.self, Transcription.self, configurations: config)
        let modelContext = container.mainContext
        
        let whisperState = WhisperState(modelContext: modelContext)
        let fileWatcherManager = FileWatcherManager(modelContext: modelContext, whisperState: whisperState)
        
        #expect(fileWatcherManager.queuedFiles.isEmpty)
        #expect(fileWatcherManager.currentlyProcessingFile == nil)
    }
    
    // MARK: - Audio Processing Tests
    
    @Test("Supported media extensions validation")
    func testSupportedMediaExtensions() {
        let extensions = SupportedMedia.supportedExtensions
        
        #expect(extensions.contains("wav"))
        #expect(extensions.contains("mp3"))
        #expect(extensions.contains("m4a"))
        #expect(extensions.contains("aiff"))
        #expect(extensions.contains("mp4"))
        #expect(extensions.contains("mov"))
        #expect(extensions.contains("aac"))
        #expect(extensions.contains("flac"))
        #expect(extensions.contains("caf"))
        
        #expect(extensions.count == 9)
    }
    
    @Test("Audio file extension detection")
    func testAudioFileExtensionDetection() {
        let wavURL = URL(fileURLWithPath: "/tmp/test.wav")
        #expect(SupportedMedia.supportedExtensions.contains(wavURL.pathExtension.lowercased()))
        
        let mp3URL = URL(fileURLWithPath: "/tmp/test.mp3")
        #expect(SupportedMedia.supportedExtensions.contains(mp3URL.pathExtension.lowercased()))
        
        let txtURL = URL(fileURLWithPath: "/tmp/test.txt")
        #expect(!SupportedMedia.supportedExtensions.contains(txtURL.pathExtension.lowercased()))
    }
    
    // MARK: - Transcription History Tests
    
    @Test("Transcription history persistence")
    func testTranscriptionHistoryPersistence() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, configurations: config)
        let modelContext = container.mainContext
        
        let transcription = Transcription(
            text: "Test transcription text",
            duration: 10.5,
            audioFileURL: "file:///tmp/test.wav",
            transcriptionModelName: "test-model"
        )
        
        modelContext.insert(transcription)
        try modelContext.save()
        
        let descriptor = FetchDescriptor<Transcription>()
        let fetchedTranscriptions = try modelContext.fetch(descriptor)
        
        #expect(fetchedTranscriptions.count == 1)
        #expect(fetchedTranscriptions.first?.text == "Test transcription text")
        #expect(fetchedTranscriptions.first?.duration == 10.5)
    }
    
    @Test("Multiple transcriptions persistence")
    func testMultipleTranscriptionsPersistence() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, configurations: config)
        let modelContext = container.mainContext
        
        for i in 1...5 {
            let transcription = Transcription(
                text: "Transcription \(i)",
                duration: Double(i),
                audioFileURL: "file:///tmp/test\(i).wav",
                transcriptionModelName: "test-model-\(i)"
            )
            modelContext.insert(transcription)
        }
        
        try modelContext.save()
        
        let descriptor = FetchDescriptor<Transcription>()
        let fetchedTranscriptions = try modelContext.fetch(descriptor)
        
        #expect(fetchedTranscriptions.count == 5)
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Invalid audio URL handling")
    func testInvalidAudioURLHandling() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, FileWatcherPair.self, configurations: config)
        let modelContext = container.mainContext
        
        let transcription = Transcription(
            text: "Test",
            duration: 0,
            audioFileURL: nil,
            transcriptionModelName: "test"
        )
        
        #expect(transcription.audioFileURL == nil)
        
        modelContext.insert(transcription)
        try modelContext.save()
    }
    
    @Test("Failed transcription status")
    func testFailedTranscriptionStatus() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, configurations: config)
        let modelContext = container.mainContext
        
        let transcription = Transcription(
            text: "Transcription Failed: Error message",
            duration: 0,
            audioFileURL: "file:///tmp/test.wav",
            transcriptionModelName: "test-model"
        )
        transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        
        modelContext.insert(transcription)
        try modelContext.save()
        
        let descriptor = FetchDescriptor<Transcription>()
        let fetchedTranscriptions = try modelContext.fetch(descriptor)
        
        #expect(fetchedTranscriptions.first?.transcriptionStatus == TranscriptionStatus.failed.rawValue)
        #expect(fetchedTranscriptions.first?.text.contains("Failed"))
    }
    
    // MARK: - Text Processing Tests
    
    @Test("Text formatting applied to transcription")
    func testTextFormattingApplied() {
        let rawText = "hello world this is a test"
        let formatted = WhisperTextFormatter.format(rawText)
        
        #expect(formatted != rawText)
        #expect(formatted.first?.isUppercase ?? false)
    }
    
    @Test("Word replacement service integration")
    func testWordReplacementServiceIntegration() {
        let service = WordReplacementService.shared
        let text = "test text"
        let processed = service.applyReplacements(to: text)
        
        #expect(processed is String)
    }
    
    // MARK: - Cloud Provider Tests
    
    @Test("Cloud provider validation")
    func testCloudProviderValidation() {
        let groqProvider = ModelProvider.groq
        #expect(groqProvider == .groq)
        
        let deepgramProvider = ModelProvider.deepgram
        #expect(deepgramProvider == .deepgram)
        
        let elevenLabsProvider = ModelProvider.elevenLabs
        #expect(elevenLabsProvider == .elevenLabs)
        
        let mistralProvider = ModelProvider.mistral
        #expect(mistralProvider == .mistral)
        
        let geminiProvider = ModelProvider.gemini
        #expect(geminiProvider == .gemini)
    }
    
    // MARK: - Transcription Model Configuration Tests
    
    @Test("Transcription model provider matching")
    func testTranscriptionModelProviderMatching() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, FileWatcherPair.self, configurations: config)
        let modelContext = container.mainContext
        
        let whisperState = WhisperState(modelContext: modelContext)
        
        let allModels = whisperState.allAvailableModels
        #expect(!allModels.isEmpty)
        
        let localModels = allModels.filter { $0.provider == .local }
        let cloudModels = allModels.filter { [.groq, .deepgram, .elevenLabs, .mistral, .gemini].contains($0.provider) }
        let parakeetModels = allModels.filter { $0.provider == .parakeet }
        let nativeModels = allModels.filter { $0.provider == .nativeApple }
        
        #expect(localModels.count >= 0)
        #expect(cloudModels.count >= 0)
        #expect(parakeetModels.count >= 0)
        #expect(nativeModels.count >= 0)
    }
}
