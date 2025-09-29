import SwiftUI

struct FileWatcherRowView: View {
    let pair: FileWatcherPair
    let onRemove: () -> Void
    let onToggleEnabled: () -> Void
    let onUpdateInputFolder: (URL) -> Void
    let onUpdateOutputFolder: (URL) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Enable/Disable toggle
                Toggle("", isOn: .constant(pair.isEnabled))
                    .toggleStyle(.switch)
                    .onChange(of: pair.isEnabled) { _, _ in
                        onToggleEnabled()
                    }

                // Input folder section
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watch Folder")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { selectInputFolder() }) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                            Text(pair.inputFolderURL.lastPathComponent.isEmpty ? "Select folder..." : pair.inputFolderURL.lastPathComponent)
                                .lineLimit(1)
                                .foregroundColor(pair.inputFolderURL.lastPathComponent.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .font(.caption)

                // Output folder section
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output Folder")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { selectOutputFolder() }) {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundColor(.green)
                            Text(pair.outputFolderURL.lastPathComponent.isEmpty ? "Select folder..." : pair.outputFolderURL.lastPathComponent)
                                .lineLimit(1)
                                .foregroundColor(pair.outputFolderURL.lastPathComponent.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Control buttons
                HStack(spacing: 8) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help("Show details")

                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove folder pair")
                }
            }

            // Expanded details section
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Full Input Path:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(pair.inputFolderPath)
                                .font(.caption)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Full Output Path:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(pair.outputFolderPath)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }

                    HStack {
                        Text("Status:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Label(
                            pair.isValid ? "Valid" : "Invalid paths",
                            systemImage: pair.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundColor(pair.isValid ? .green : .orange)

                        Spacer()

                        Text("Created: \(pair.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(pair.isEnabled ? 1.0 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            pair.isValid ? Color.clear : Color.orange.opacity(0.5),
                            lineWidth: 1
                        )
                )
        )
    }

    private func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Input Folder to Watch"
        panel.message = "Choose the folder where audio files will be dropped for automatic transcription"

        if panel.runModal() == .OK, let url = panel.url {
            onUpdateInputFolder(url)
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Output Folder"
        panel.message = "Choose the folder where transcription files will be saved"

        if panel.runModal() == .OK, let url = panel.url {
            onUpdateOutputFolder(url)
        }
    }
}