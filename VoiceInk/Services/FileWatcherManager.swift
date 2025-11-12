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
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            Task { @MainActor in
                for fileURL in files {
                    // Skip .meta.json files during scanning
                    if fileURL.lastPathComponent.hasSuffix(".meta.json") {
                        continue
                    }
                    
                    // Check if it's a supported audio/video file
                    guard SupportedMedia.isSupported(url: fileURL) else { continue }

                    // Avoid queueing the same file multiple times
                    guard !self.queuedFiles.contains(fileURL) else { continue }
                    guard !self.processingFiles.contains(fileURL) else { continue }

                    // Verify file is fully written by checking if it's stable
                    guard await self.isFileStable(fileURL) else {
                        self.logger.info("File not stable yet, will retry: \(fileURL.lastPathComponent)")
                        continue
                    }

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

    private func isFileStable(_ fileURL: URL) async -> Bool {
        do {
            let resources1 = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let size1 = resources1.fileSize ?? 0
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let resources2 = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let size2 = resources2.fileSize ?? 0
            
            return size1 == size2 && size1 > 0
        } catch {
            logger.error("Failed to check file stability: \(error.localizedDescription)")
            return false
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

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.warning("File no longer exists, skipping: \(fileURL.lastPathComponent)")
            return
        }

        processingFiles.insert(fileURL)
        currentlyProcessingFile = fileURL
        logger.info("Processing file: \(fileURL.lastPathComponent)")

        let metadata = readMetadataFile(audioURL: fileURL)
        if metadata != nil {
            logger.info("Found metadata sidecar for \(fileURL.lastPathComponent)")
        }

        do {
            guard let currentModel = whisperState.currentTranscriptionModel else {
                throw TranscriptionError.noModelSelected
            }

            let samples = try await audioProcessor.processAudioToSamples(fileURL)
            let audioAsset = AVURLAsset(url: fileURL)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            let tempDirectory = FileManager.default.temporaryDirectory
            let tempFileName = "filewatcher_\(UUID().uuidString).wav"
            let tempURL = tempDirectory.appendingPathComponent(tempFileName)
            try audioProcessor.saveSamplesAsWav(samples: samples, to: tempURL)

            let text = try await transcribeAudio(tempURL: tempURL, model: currentModel, whisperState: whisperState)

            var finalText = TranscriptionOutputFilter.filter(text)
            finalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.object(forKey: "IsTextFormattingEnabled") as? Bool ?? true {
                finalText = WhisperTextFormatter.format(finalText)
            }

            if UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled") {
                finalText = WordReplacementService.shared.applyReplacements(to: finalText)
            }

            let outputURL = determineOutputPath(metadata: metadata, pair: pair, filename: fileURL.lastPathComponent)
            let outputDir = outputURL.deletingLastPathComponent()
            
            if !FileManager.default.fileExists(atPath: outputDir.path) {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                logger.info("Created output directory: \(outputDir.path)")
            }

            let transcriptionOutput: TranscriptionOutput
            if let metadata = metadata {
                transcriptionOutput = TranscriptionOutput.forPodcast(
                    transcription: finalText,
                    podcastMetadata: metadata,
                    audioFilePath: fileURL.lastPathComponent,
                    confidenceScore: nil,
                    language: nil
                )
            } else if let videoId = extractYouTubeVideoId(from: fileURL.lastPathComponent) {
                transcriptionOutput = TranscriptionOutput.forYouTube(
                    transcription: finalText,
                    videoId: videoId,
                    audioFilePath: fileURL.lastPathComponent,
                    durationSeconds: Int(duration),
                    confidenceScore: nil,
                    language: nil,
                    flowType: nil
                )
            } else {
                let outputMetadata = TranscriptionOutput.TranscriptionMetadata(
                    sourceType: "audio_transcription",
                    flowType: nil,
                    audioFilePath: fileURL.lastPathComponent,
                    durationSeconds: Int(duration),
                    confidenceScore: nil,
                    language: nil
                )
                transcriptionOutput = TranscriptionOutput(
                    text: finalText,
                    title: nil,
                    metadata: outputMetadata
                )
            }
            
            try transcriptionOutput.write(to: outputURL)

            let transcription = Transcription(
                text: finalText,
                duration: duration,
                audioFileURL: fileURL.absoluteString,
                transcriptionModelName: currentModel.displayName
            )

            modelContext.insert(transcription)
            try modelContext.save()

            try? FileManager.default.removeItem(at: tempURL)

            let metadataURL = fileURL.deletingPathExtension().appendingPathExtension("meta.json")
            var filesToDelete = [fileURL]
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                filesToDelete.append(metadataURL)
            }

            var allDeleted = true
            for fileToDelete in filesToDelete {
                do {
                    try FileManager.default.removeItem(at: fileToDelete)
                    logger.info("Deleted: \(fileToDelete.lastPathComponent)")
                } catch {
                    allDeleted = false
                    cleanupFailedFiles.insert(fileToDelete)
                    logger.error("Failed to delete \(fileToDelete.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            if allDeleted {
                cleanupFailedFiles.remove(fileURL)
                cleanupFailedFiles.remove(metadataURL)
                logger.info("Successfully processed and deleted file: \(fileURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
            } else {
                logger.info("Successfully processed file: \(fileURL.lastPathComponent) -> \(outputURL.lastPathComponent) (cleanup partially failed)")
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
            let parakeetService = ParakeetTranscriptionService()
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
    
    private func readMetadataFile(audioURL: URL) -> PodcastMetadata? {
        let metadataURL = audioURL.deletingPathExtension().appendingPathExtension("meta.json")
        
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        
        do {
            return try PodcastMetadata.load(from: metadataURL)
        } catch {
            logger.warning("Failed to parse metadata file \(metadataURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func determineOutputPath(metadata: PodcastMetadata?, pair: FileWatcherPair, filename: String) -> URL {
        let baseOutputURL = pair.outputFolderURL
        let basename = (filename as NSString).deletingPathExtension
        let outputFilename = "\(basename).json"
        
        if let metadata = metadata {
            let flowTypeDir = metadata.flowType.rawValue
            let sourceTypeDir = "podcasts"
            let subdirPath = "\(flowTypeDir)/\(sourceTypeDir)/01_raw"
            
            return baseOutputURL
                .appendingPathComponent(subdirPath)
                .appendingPathComponent(outputFilename)
        } else if extractYouTubeVideoId(from: filename) != nil {
            let flowTypeDir = "simple"
            let sourceTypeDir = "adhoc"
            let subdirPath = "\(flowTypeDir)/\(sourceTypeDir)/01_raw"
            
            return baseOutputURL
                .appendingPathComponent(subdirPath)
                .appendingPathComponent(outputFilename)
        } else {
            let flowTypeDir = "simple"
            let sourceTypeDir = "adhoc"
            let subdirPath = "\(flowTypeDir)/\(sourceTypeDir)/01_raw"
            
            return baseOutputURL
                .appendingPathComponent(subdirPath)
                .appendingPathComponent(outputFilename)
        }
    }
    
    private func extractYouTubeVideoId(from filename: String) -> String? {
        return TranscriptionOutput.extractYouTubeVideoId(from: filename)
    }
}