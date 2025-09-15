import SwiftUI
import SwiftData

struct TranscriptionCleanupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcription.timestamp, order: .reverse) private var allTranscriptions: [Transcription]
    @State private var selectedTranscription: Transcription?
    @State private var showingDeleteConfirmation = false
    @State private var showOnlyToday = false
    
    private var transcriptions: [Transcription] {
        let filtered: [Transcription]
        if showOnlyToday {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            
            filtered = allTranscriptions.filter { transcription in
                transcription.timestamp >= today && transcription.timestamp < tomorrow
            }
        } else {
            filtered = allTranscriptions
        }
        
        // Sort by transcription processing time descending, then by timestamp descending
        return filtered.sorted { first, second in
            let firstProcessingTime = first.transcriptionDuration ?? 0
            let secondProcessingTime = second.transcriptionDuration ?? 0

            if firstProcessingTime != secondProcessingTime {
                return firstProcessingTime > secondProcessingTime
            }
            return first.timestamp > second.timestamp
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                Text("Transcription Cleanup Utility")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                HStack {
                    Toggle("Show only today's transcriptions", isOn: $showOnlyToday)
                        .toggleStyle(SwitchToggleStyle())
                    Spacer()
                }
                .padding(.horizontal)
                
                VStack {
                    Text("Found \(transcriptions.count) transcriptions \(showOnlyToday ? "from today" : "total")")
                        .foregroundColor(.secondary)
                    
                    if !transcriptions.isEmpty {
                        let maxProcessingTime = transcriptions.compactMap { $0.transcriptionDuration }.max() ?? 0
                        Text("Longest processing: \(String(format: "%.1f", maxProcessingTime))s")
                            .font(.caption)
                            .foregroundColor(maxProcessingTime > 30 ? .red : .secondary)
                    }
                }
                .padding(.bottom)
                
                List {
                    ForEach(Array(transcriptions.enumerated()), id: \.element.id) { index, transcription in
                        TranscriptionRowView(
                            transcription: transcription,
                            index: index + 1,
                            onDelete: {
                                selectedTranscription = transcription
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
            .navigationTitle("Cleanup Transcriptions")
            .alert("Delete Transcription", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let transcription = selectedTranscription {
                        deleteTranscription(transcription)
                    }
                }
            } message: {
                if let transcription = selectedTranscription {
                    let processingTime = transcription.transcriptionDuration ?? 0
                    let audioMinutes = transcription.duration / 60
                    Text("Are you sure you want to delete this transcription (processed in \(String(format: "%.1f", processingTime))s, \(String(format: "%.1f", audioMinutes)) min audio)? This action cannot be undone.")
                }
            }
        }
    }
    
    private func deleteTranscription(_ transcription: Transcription) {
        modelContext.delete(transcription)
        
        do {
            try modelContext.save()
        } catch {
            print("Error deleting transcription: \(error)")
        }
        
        selectedTranscription = nil
    }
}

struct TranscriptionRowView: View {
    let transcription: Transcription
    let index: Int
    let onDelete: () -> Void
    
    private var processingTimeSeconds: Double {
        transcription.transcriptionDuration ?? 0
    }

    private var audioDurationMinutes: Double {
        transcription.duration / 60
    }
    
    private var textPreview: String {
        String(transcription.text.prefix(50)) + (transcription.text.count > 50 ? "..." : "")
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(index).")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if processingTimeSeconds > 30 {
                                Text("⚠️ Processing: \(String(format: "%.1f", processingTimeSeconds))s")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                            } else if processingTimeSeconds > 0 {
                                Text("Processing: \(String(format: "%.1f", processingTimeSeconds))s")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            } else {
                                Text("Processing: N/A")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Audio: \(String(format: "%.1f", audioDurationMinutes)) min")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Text("Source: \(transcription.source ?? "ui")")
                        .font(.caption)
                    
                    if let filename = transcription.filename {
                        Text("• File: \(filename)")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
                
                Text("Date: \(dateFormatter.string(from: transcription.timestamp))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(textPreview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()

            Button("Delete", action: onDelete)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(processingTimeSeconds > 30 ? .red : .secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TranscriptionCleanupView()
        .modelContainer(for: Transcription.self, inMemory: true)
}