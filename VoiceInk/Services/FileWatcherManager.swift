import Foundation
import SwiftData
import AVFoundation
import os

@MainActor
class FileWatcherManager: ObservableObject {
    static let shared = FileWatcherManager()

    @Published var isWatching = false
    @Published var watchedPairs: [FileWatcherPair] = []
    @Published var processingFiles: Set<URL> = []
    @Published var cleanupFailedFiles: Set<URL> = []
    @Published var queuedFiles: [URL] = []
    @Published var currentlyProcessingFile: URL?

    private var fileSystemSources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "com.voiceink.filewatcher", qos: .background)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FileWatcherManager")
    private var isProcessingQueue = false
    private var fileToWatcherPairMap: [URL: FileWatcherPair] = [:]

    // Dependencies
    private var modelContext: ModelContext?
    private var whisperState: WhisperState?
    private let audioProcessor = AudioProcessor()

    private init() {}

    func configure(modelContext: ModelContext, whisperState: WhisperState) {
        self.modelContext = modelContext
        self.whisperState = whisperState
        loadWatchedPairs()
    }

    func startWatching() {
        guard !isWatching else { return }

        stopWatching() // Clean up any existing watchers

        for pair in watchedPairs where pair.isEnabled && pair.isValid {
            startWatchingFolder(pair: pair)
        }

        isWatching = !fileSystemSources.isEmpty
        logger.info("Started watching \(self.fileSystemSources.count) folder pairs")
    }

    func stopWatching() {
        fileSystemSources.forEach { source in
            source.cancel()
        }
        fileSystemSources.removeAll()
        isWatching = false
        // Clear cleanup failed files when stopping
        cleanupFailedFiles.removeAll()
        // Clear queue when stopping
        queuedFiles.removeAll()
        currentlyProcessingFile = nil
        fileToWatcherPairMap.removeAll()
        logger.info("Stopped watching all folder pairs")
    }

    func addWatcherPair(inputFolder: URL, outputFolder: URL) {
        let pair = FileWatcherPair(
            inputFolderPath: inputFolder.path,
            outputFolderPath: outputFolder.path
        )

        watchedPairs.append(pair)
        saveWatchedPairs()

        if isWatching {
            startWatchingFolder(pair: pair)
        }
    }

    func removeWatcherPair(_ pair: FileWatcherPair) {
        if let index = watchedPairs.firstIndex(where: { $0.id == pair.id }) {
            watchedPairs.remove(at: index)
            saveWatchedPairs()

            // Restart watching to remove the specific watcher
            if isWatching {
                startWatching()
            }
        }
    }

    func togglePairEnabled(_ pair: FileWatcherPair) {
        pair.isEnabled.toggle()
        saveWatchedPairs()

        // Restart watching to apply changes
        if isWatching {
            startWatching()
        }
    }

    private func startWatchingFolder(pair: FileWatcherPair) {
        let folderPath = pair.inputFolderPath

        guard FileManager.default.fileExists(atPath: folderPath) else {
            logger.error("Input folder does not exist: \(folderPath)")
            return
        }

        let folderDescriptor = open(folderPath, O_EVTONLY)
        guard folderDescriptor >= 0 else {
            logger.error("Could not open folder for watching: \(folderPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderDescriptor,
            eventMask: .write,
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleFolderChange(pair: pair)
        }

        source.setCancelHandler {
            close(folderDescriptor)
        }

        source.resume()
        fileSystemSources.append(source)

        logger.info("Started watching folder: \(folderPath)")
    }

    private func handleFolderChange(pair: FileWatcherPair) {
        // Wait a bit for file operations to complete
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.scanFolderForNewFiles(pair: pair)
        }
    }

    private func scanFolderForNewFiles(pair: FileWatcherPair) {
        let inputURL = pair.inputFolderURL

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: inputURL,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            Task { @MainActor in
                for fileURL in files {
                    // Check if it's a supported audio/video file
                    guard SupportedMedia.isSupported(url: fileURL) else { continue }

                    // Avoid queueing the same file multiple times
                    guard !self.queuedFiles.contains(fileURL) else { continue }
                    guard !self.processingFiles.contains(fileURL) else { continue }

                    // Add to queue and map to watcher pair
                    self.queuedFiles.append(fileURL)
                    self.fileToWatcherPairMap[fileURL] = pair
                    self.logger.info("Queued file: \(fileURL.lastPathComponent)")
                }

                // Start processing the queue
                await self.processQueue()
            }
        } catch {
            logger.error("Error scanning folder \(inputURL.path): \(error.localizedDescription)")
        }
    }

    private func processQueue() async {
        // Prevent concurrent queue processing
        guard !isProcessingQueue else { return }
        guard !queuedFiles.isEmpty else { return }

        isProcessingQueue = true

        while let fileURL = queuedFiles.first {
            // Remove from queue and get associated watcher pair
            queuedFiles.removeFirst()
            guard let pair = fileToWatcherPairMap[fileURL] else {
                logger.error("No watcher pair found for file: \(fileURL.lastPathComponent)")
                continue
            }

            // Process this file
            await processFile(fileURL: fileURL, pair: pair)

            // Clean up the mapping
            fileToWatcherPairMap.removeValue(forKey: fileURL)
        }

        isProcessingQueue = false
    }

    private func processFile(fileURL: URL, pair: FileWatcherPair) async {
        guard let modelContext = modelContext,
              let whisperState = whisperState else {
            logger.error("Missing dependencies for transcription")
            return
        }

        guard !processingFiles.contains(fileURL) else { return }

        processingFiles.insert(fileURL)
        currentlyProcessingFile = fileURL
        logger.info("Processing file: \(fileURL.lastPathComponent)")

        do {
            // Get current model
            guard let currentModel = whisperState.currentTranscriptionModel else {
                throw TranscriptionError.noModelSelected
            }

            // Process audio
            let samples = try await audioProcessor.processAudioToSamples(fileURL)
            let audioAsset = AVURLAsset(url: fileURL)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            // Create temporary copy for transcription
            let tempDirectory = FileManager.default.temporaryDirectory
            let tempFileName = "filewatcher_\(UUID().uuidString).wav"
            let tempURL = tempDirectory.appendingPathComponent(tempFileName)
            try audioProcessor.saveSamplesAsWav(samples: samples, to: tempURL)

            // Transcribe using appropriate service
            let text = try await transcribeAudio(tempURL: tempURL, model: currentModel, whisperState: whisperState)

            // Apply text formatting and replacements
            var finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
                finalText = WhisperTextFormatter.format(finalText)
            }

            if UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled") {
                finalText = WordReplacementService.shared.applyReplacements(to: finalText)
            }

            // Save transcript to output folder
            let outputFileName = fileURL.deletingPathExtension().lastPathComponent + "_transcript.txt"
            let outputURL = pair.outputFolderURL.appendingPathComponent(outputFileName)

            try finalText.write(to: outputURL, atomically: true, encoding: .utf8)

            // Create transcription record
            let transcription = Transcription(
                text: finalText,
                duration: duration,
                audioFileURL: fileURL.absoluteString,
                transcriptionModelName: currentModel.displayName
            )

            modelContext.insert(transcription)
            try modelContext.save()

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            // Delete the original input file after successful transcription
            do {
                try FileManager.default.removeItem(at: fileURL)
                // Remove from cleanup failed files if it was previously there
                cleanupFailedFiles.remove(fileURL)
                logger.info("Successfully processed and deleted file: \(fileURL.lastPathComponent) -> \(outputFileName)")
            } catch {
                // Track files that failed cleanup
                cleanupFailedFiles.insert(fileURL)
                logger.error("Failed to delete input file \(fileURL.lastPathComponent) after transcription: \(error.localizedDescription)")
                // Still log success since transcription worked
                logger.info("Successfully processed file: \(fileURL.lastPathComponent) -> \(outputFileName) (file cleanup failed)")
            }

        } catch {
            logger.error("Error processing file \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }

        processingFiles.remove(fileURL)
        currentlyProcessingFile = nil
    }

    private func transcribeAudio(tempURL: URL, model: any TranscriptionModel, whisperState: WhisperState) async throws -> String {
        switch model.provider {
        case .local:
            let localService = LocalTranscriptionService(modelsDirectory: whisperState.modelsDirectory, whisperState: whisperState)
            return try await localService.transcribe(audioURL: tempURL, model: model)
        case .parakeet:
            let parakeetService = ParakeetTranscriptionService(customModelsDirectory: whisperState.parakeetModelsDirectory)
            return try await parakeetService.transcribe(audioURL: tempURL, model: model)
        case .nativeApple:
            let nativeService = NativeAppleTranscriptionService()
            return try await nativeService.transcribe(audioURL: tempURL, model: model)
        default:
            let cloudService = CloudTranscriptionService()
            return try await cloudService.transcribe(audioURL: tempURL, model: model)
        }
    }

    private func loadWatchedPairs() {
        guard let modelContext = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<FileWatcherPair>()
            watchedPairs = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to load watcher pairs: \(error.localizedDescription)")
            watchedPairs = []
        }
    }

    func saveWatchedPairs() {
        guard let modelContext = modelContext else { return }

        do {
            // Remove all existing pairs and re-insert current ones
            let descriptor = FetchDescriptor<FileWatcherPair>()
            let existingPairs = try modelContext.fetch(descriptor)
            for pair in existingPairs {
                modelContext.delete(pair)
            }

            // Insert current pairs
            for pair in watchedPairs {
                modelContext.insert(pair)
            }

            try modelContext.save()
        } catch {
            logger.error("Failed to save watcher pairs: \(error.localizedDescription)")
        }
    }
}