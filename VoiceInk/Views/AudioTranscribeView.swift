import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct AudioTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var whisperState: WhisperState
    @StateObject private var transcriptionManager = AudioTranscriptionManager.shared
    @StateObject private var fileWatcherManager = FileWatcherManager.shared
    @State private var isDropTargeted = false
    @State private var selectedAudioURL: URL?
    @State private var isAudioFileSelected = false
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?
    
    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 0) {
                    if transcriptionManager.isProcessing {
                        processingView
                    } else {
                        dropZoneView
                    }

                    Divider()
                        .padding(.vertical)

                    // File Watcher Section
                    fileWatcherSection

                    Divider()
                        .padding(.vertical)

                    // Show current transcription result
                    if let transcription = transcriptionManager.currentTranscription {
                        TranscriptionResultView(transcription: transcription)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL, .data, .audio, .movie], isTargeted: $isDropTargeted) { providers in
            if !transcriptionManager.isProcessing && !isAudioFileSelected {
                handleDroppedFile(providers)
                return true
            }
            return false
        }
        .alert("Error", isPresented: .constant(transcriptionManager.errorMessage != nil)) {
            Button("OK", role: .cancel) {
                transcriptionManager.errorMessage = nil
            }
        } message: {
            if let errorMessage = transcriptionManager.errorMessage {
                Text(errorMessage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                // Do not auto-start; only select file for manual transcription
                validateAndSetAudioFile(url)
            }
        }
        .onAppear {
            fileWatcherManager.configure(modelContext: modelContext, whisperState: whisperState)
        }
    }
    
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            if isAudioFileSelected {
                VStack(spacing: 16) {
                    Text("Audio file selected: \(selectedAudioURL?.lastPathComponent ?? "")")
                        .font(.headline)
                    
                    // AI Enhancement Settings
                    if let enhancementService = whisperState.getEnhancementService() {
                        VStack(spacing: 16) {
                            // AI Enhancement and Prompt in the same row
                            HStack(spacing: 16) {
                                Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                                    .toggleStyle(.switch)
                                    .onChange(of: isEnhancementEnabled) { oldValue, newValue in
                                        enhancementService.isEnhancementEnabled = newValue
                                    }
                                
                                if isEnhancementEnabled {
                                    Divider()
                                        .frame(height: 20)
                                    
                                    // Prompt Selection
                                    HStack(spacing: 8) {
                                        Text("Prompt:")
                                            .font(.subheadline)
                                        
                                        if enhancementService.allPrompts.isEmpty {
                                            Text("No prompts available")
                                                .foregroundColor(.secondary)
                                                .italic()
                                                .font(.caption)
                                        } else {
                                            let promptBinding = Binding<UUID>(
                                                get: {
                                                    selectedPromptId ?? enhancementService.allPrompts.first?.id ?? UUID()
                                                },
                                                set: { newValue in
                                                    selectedPromptId = newValue
                                                    enhancementService.selectedPromptId = newValue
                                                }
                                            )
                                            
                                            Picker("", selection: promptBinding) {
                                                ForEach(enhancementService.allPrompts) { prompt in
                                                    Text(prompt.title).tag(prompt.id)
                                                }
                                            }
                                            .labelsHidden()
                                            .fixedSize()
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                                        .background(CardBackground(isSelected: false))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onAppear {
                            // Initialize local state from enhancement service
                            isEnhancementEnabled = enhancementService.isEnhancementEnabled
                            selectedPromptId = enhancementService.selectedPromptId
                        }
                    }
                    
                    // Action Buttons in a row
                    HStack(spacing: 12) {
                        Button("Start Transcription") {
                            if let url = selectedAudioURL {
                                transcriptionManager.startProcessing(
                                    url: url,
                                    modelContext: modelContext,
                                    whisperState: whisperState
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Choose Different File") {
                            selectedAudioURL = nil
                            isAudioFileSelected = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.windowBackgroundColor).opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    style: StrokeStyle(
                                        lineWidth: 2,
                                        dash: [8]
                                    )
                                )
                                .foregroundColor(isDropTargeted ? .blue : .gray.opacity(0.5))
                        )
                    
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 32))
                            .foregroundColor(isDropTargeted ? .blue : .gray)
                        
                        Text("Drop audio or video file here")
                            .font(.headline)
                        
                        Text("or")
                            .foregroundColor(.secondary)
                        
                        Button("Choose File") {
                            selectFile()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(32)
                }
                .frame(height: 200)
                .padding(.horizontal)
            }
            
            Text("Supported formats: WAV, MP3, M4A, AIFF, MP4, MOV")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.8)
            Text(transcriptionManager.processingPhase.message)
                .font(.headline)
        }
        .padding()
    }
    
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio, .movie
        ]
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                selectedAudioURL = url
                isAudioFileSelected = true
            }
        }
    }
    
    private func handleDroppedFile(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        // List of type identifiers to try
        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.movie.identifier,
            UTType.data.identifier,
            "public.file-url"
        ]
        
        // Try each type identifier
        for typeIdentifier in typeIdentifiers {
            if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { (item, error) in
                    if let error = error {
                        print("Error loading dropped file with type \(typeIdentifier): \(error)")
                        return
                    }
                    
                    var fileURL: URL?
                    
                    if let url = item as? URL {
                        fileURL = url
                    } else if let data = item as? Data {
                        // Try to create URL from data
                        if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            fileURL = url
                        } else if let urlString = String(data: data, encoding: .utf8),
                                  let url = URL(string: urlString) {
                            fileURL = url
                        }
                    } else if let urlString = item as? String {
                        fileURL = URL(string: urlString)
                    }
                    
                    if let finalURL = fileURL {
                        DispatchQueue.main.async {
                            self.validateAndSetAudioFile(finalURL)
                        }
                        return
                    }
                }
                break // Stop trying other types once we find a compatible one
            }
        }
    }
    
    private func validateAndSetAudioFile(_ url: URL) {
        print("Attempting to validate file: \(url.path)")
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("File does not exist at path: \(url.path)")
            return
        }
        
        // Try to access security scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Validate file type
        guard SupportedMedia.isSupported(url: url) else { return }
        
        print("File validated successfully: \(url.lastPathComponent)")
        selectedAudioURL = url
        isAudioFileSelected = true
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var fileWatcherSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder Watcher")
                        .font(.headline)

                    Text("Automatically transcribe and delete files dropped into watched folders")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: {
                        if fileWatcherManager.isWatching {
                            fileWatcherManager.stopWatching()
                        } else {
                            fileWatcherManager.startWatching()
                        }
                    }) {
                        Label(
                            fileWatcherManager.isWatching ? "Stop Watching" : "Start Watching",
                            systemImage: fileWatcherManager.isWatching ? "stop.circle.fill" : "play.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(fileWatcherManager.watchedPairs.isEmpty)

                    Button(action: addWatcherPair) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .help("Add folder pair")
                }
            }

            if fileWatcherManager.watchedPairs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)

                    Text("No folder pairs configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Add a folder pair to automatically transcribe files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Add First Folder Pair", action: addWatcherPair)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(fileWatcherManager.watchedPairs, id: \.id) { pair in
                        FileWatcherRowView(
                            pair: pair,
                            onRemove: {
                                fileWatcherManager.removeWatcherPair(pair)
                            },
                            onToggleEnabled: {
                                fileWatcherManager.togglePairEnabled(pair)
                            },
                            onUpdateInputFolder: { url in
                                pair.inputFolderPath = url.path
                                fileWatcherManager.saveWatchedPairs()
                            },
                            onUpdateOutputFolder: { url in
                                pair.outputFolderPath = url.path
                                fileWatcherManager.saveWatchedPairs()
                            }
                        )
                    }
                }
            }

            if fileWatcherManager.isWatching {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .scaleEffect(fileWatcherManager.processingFiles.isEmpty ? 1.0 : 1.5)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: fileWatcherManager.processingFiles.isEmpty)

                        Text("Watching \(fileWatcherManager.watchedPairs.filter(\.isEnabled).count) folder(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !fileWatcherManager.queuedFiles.isEmpty {
                            Text("• \(fileWatcherManager.queuedFiles.count) queued")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        if !fileWatcherManager.processingFiles.isEmpty {
                            Text("• Processing \(fileWatcherManager.processingFiles.count) file(s)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }

                        if !fileWatcherManager.cleanupFailedFiles.isEmpty {
                            Text("• \(fileWatcherManager.cleanupFailedFiles.count) cleanup issue(s)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        Spacer()
                    }

                    // Show currently processing file
                    if let currentFile = fileWatcherManager.currentlyProcessingFile {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)

                            Text("Processing: \(currentFile.lastPathComponent)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    // Show queued files
                    if !fileWatcherManager.queuedFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Queued files:")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            ForEach(fileWatcherManager.queuedFiles.prefix(5), id: \.self) { fileURL in
                                HStack(spacing: 6) {
                                    Image(systemName: "clock")
                                        .font(.caption2)
                                        .foregroundColor(.orange)

                                    Text(fileURL.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            if fileWatcherManager.queuedFiles.count > 5 {
                                Text("+ \(fileWatcherManager.queuedFiles.count - 5) more")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
        )
        .padding(.horizontal)
    }

    private func addWatcherPair() {
        let inputPanel = NSOpenPanel()
        inputPanel.allowsMultipleSelection = false
        inputPanel.canChooseDirectories = true
        inputPanel.canChooseFiles = false
        inputPanel.title = "Select Input Folder to Watch"
        inputPanel.message = "Choose the folder where audio files will be dropped for automatic transcription"

        guard inputPanel.runModal() == .OK, let inputURL = inputPanel.url else {
            return
        }

        let outputPanel = NSOpenPanel()
        outputPanel.allowsMultipleSelection = false
        outputPanel.canChooseDirectories = true
        outputPanel.canChooseFiles = false
        outputPanel.title = "Select Output Folder"
        outputPanel.message = "Choose the folder where transcription files will be saved"

        guard outputPanel.runModal() == .OK, let outputURL = outputPanel.url else {
            return
        }

        fileWatcherManager.addWatcherPair(inputFolder: inputURL, outputFolder: outputURL)
    }
}
