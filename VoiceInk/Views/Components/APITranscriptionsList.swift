import SwiftUI
import SwiftData

struct APITranscriptionsList: View {
    @EnvironmentObject private var apiServer: TranscriptionAPIServer
    @State private var animateProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            if !apiServer.activeTranscriptions.isEmpty {
                VStack(spacing: 12) {
                    // Header
                    HStack {
                        Text("API Transcriptions")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer()

                        // Queue info
                        if !apiServer.transcriptionQueue.isEmpty {
                            Text("\(apiServer.transcriptionQueue.count) in queue")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        // Force stop button if any active
                        if apiServer.currentProcessingRequest != nil || !apiServer.transcriptionQueue.isEmpty {
                            Button("Stop All") {
                                apiServer.forceStopAPIProcessing()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    // List of transcriptions
                    LazyVStack(spacing: 8) {
                        ForEach(apiServer.activeTranscriptions) { request in
                            APITranscriptionCard(
                                request: request,
                                onCancel: { request in
                                    if request.status == .queued {
                                        apiServer.cancelQueuedRequest(request)
                                    }
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: apiServer.activeTranscriptions.count)
    }
}

struct APITranscriptionCard: View {
    @ObservedObject var request: APITranscriptionRequest
    let onCancel: (APITranscriptionRequest) -> Void
    @State private var animationRotation: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon

            // Main content
            VStack(alignment: .leading, spacing: 4) {
                // File name and size
                HStack {
                    Text(request.displayFilename)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(request.formattedFileSize)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Spacer()

                    // Status badge
                    statusBadge
                }

                // Progress info
                Text(request.processingInfo)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Progress bar (only for processing)
                if request.status == .processing && request.progress > 0 {
                    ProgressView(value: request.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .scaleEffect(y: 0.8)
                        .animation(.easeInOut(duration: 0.3), value: request.progress)
                }

                // Timing info
                HStack {
                    Text("Elapsed: \(request.formattedElapsedTime)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.secondary.opacity(0.7))

                    if let processingTime = request.processingTime {
                        Text("• Processing: \(Int(processingTime))s")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary.opacity(0.7))
                    }

                    Spacer()

                    // Queue position for queued items
                    if request.status == .queued && request.queuePosition > 0 {
                        Text("Position #\(request.queuePosition)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }
            }

            // Action buttons
            VStack(spacing: 8) {
                if request.status == .queued {
                    Button(action: {
                        onCancel(request)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Cancel queued request")
                }

                if request.status == .completed && request.transcriptionText != nil {
                    Button(action: {
                        copyTranscriptionText(request.transcriptionText!)
                    }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 16))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Copy transcription to clipboard")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColorForStatus(request.status))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColorForStatus(request.status), lineWidth: 1)
                )
        )
        .onAppear {
            if request.status == .processing {
                startProgressAnimation()
            }
        }
        .onChange(of: request.status) { newStatus in
            if newStatus == .processing {
                startProgressAnimation()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch request.status {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
        case .processing:
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.blue)
                .rotationEffect(.degrees(animationRotation))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(request.status.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badgeColorForStatus(request.status))
            )
    }

    private func startProgressAnimation() {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            animationRotation = 360
        }
    }

    private func backgroundColorForStatus(_ status: APITranscriptionStatus) -> Color {
        switch status {
        case .queued:
            return Color.orange.opacity(0.05)
        case .processing:
            return Color.blue.opacity(0.08)
        case .completed:
            return Color.green.opacity(0.05)
        case .failed:
            return Color.red.opacity(0.05)
        case .cancelled:
            return Color.gray.opacity(0.05)
        }
    }

    private func borderColorForStatus(_ status: APITranscriptionStatus) -> Color {
        switch status {
        case .queued:
            return Color.orange.opacity(0.3)
        case .processing:
            return Color.blue.opacity(0.4)
        case .completed:
            return Color.green.opacity(0.3)
        case .failed:
            return Color.red.opacity(0.3)
        case .cancelled:
            return Color.gray.opacity(0.3)
        }
    }

    private func badgeColorForStatus(_ status: APITranscriptionStatus) -> Color {
        switch status {
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    private func copyTranscriptionText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // TODO: Show a brief success message
        print("Copied transcription to clipboard")
    }
}

// Preview temporarily disabled to avoid compilation issues
// #Preview {
//     // Preview content here
// }