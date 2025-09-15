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
        
        // Sort by duration descending to show longest first, then by timestamp descending
        return filtered.sorted { first, second in
            if first.duration != second.duration {
                return first.duration > second.duration
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
                        let maxDuration = transcriptions.max(by: { $0.duration < $1.duration })?.duration ?? 0
                        let maxHours = maxDuration / 3600
                        Text("Longest: \(String(format: "%.1f", maxHours)) hours")
                            .font(.caption)
                            .foregroundColor(maxHours > 1 ? .red : .secondary)
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
                    let durationHours = transcription.duration / 3600
                    Text("Are you sure you want to delete this \(String(format: "%.2f", durationHours)) hour transcription? This action cannot be undone.")
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
    
    private var durationHours: Double {
        transcription.duration / 3600
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
                    
                    if durationHours >= 1 {
                        Text("⚠️ \(String(format: "%.1f", durationHours)) hours")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    } else {
                        Text("\(String(format: "%.1f", durationHours * 60)) minutes")
                            .font(.subheadline)
                            .foregroundColor(.primary)
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
            
            if durationHours > 1 {
                Button("Delete", action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TranscriptionCleanupView()
        .modelContainer(for: Transcription.self, inMemory: true)
}