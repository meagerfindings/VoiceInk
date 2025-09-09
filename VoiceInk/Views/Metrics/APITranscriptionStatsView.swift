import SwiftUI

struct APITranscriptionStatsView: View {
    @EnvironmentObject private var apiServer: TranscriptionAPIServer
    
    // Computed properties for API metrics
    private var timeSaved: TimeInterval {
        apiServer.totalAudioDuration - apiServer.totalAPIProcessingTime
    }
    
    private var speedMultiplier: Double {
        guard apiServer.totalAPIProcessingTime > 0 else { return 0 }
        let multiplier = apiServer.totalAudioDuration / apiServer.totalAPIProcessingTime
        return round(multiplier * 10) / 10  // Round to 1 decimal place
    }
    
    private var speedMultiplierFormatted: String {
        String(format: "%.1fx", speedMultiplier)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            mainContent
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 24) {
            headerSection
            timeComparisonSection
            bottomSection
        }
        .padding(.vertical, 24)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(radius: 2)
    }
    
    private var headerSection: some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Text("API Transcriptions are")
                    .font(.system(size: 28, weight: .bold))
                
                Text("\(speedMultiplierFormatted) Faster")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(apiGradient)
                
                Text("than real-time")
                    .font(.system(size: 28, weight: .bold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 24)
    }
    
    private var timeComparisonSection: some View {
        HStack(spacing: 16) {
            APITimeBlockView(
                duration: apiServer.totalAudioDuration,
                label: "TOTAL AUDIO",
                icon: "waveform.circle.fill",
                color: .blue
            )
            
            APITimeBlockView(
                duration: apiServer.totalAPIProcessingTime,
                label: "PROCESSING TIME",
                icon: "clock.fill",
                color: .purple
            )
        }
        .padding(.horizontal, 24)
    }
    
    private var bottomSection: some View {
        HStack {
            VStack(spacing: 20) {
                timeSavedView
                transcriptionStatsView
            }
            Spacer()
            apiInfoView
        }
        .padding(.horizontal, 24)
    }
    
    private var timeSavedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIME SAVED ⚡")
                .font(.system(size: 13, weight: .heavy))
                .tracking(4)
                .foregroundColor(.secondary)
            
            Text(formatDuration(timeSaved))
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(apiGradient)
        }
    }
    
    private var transcriptionStatsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRANSCRIPTIONS PROCESSED")
                .font(.system(size: 11, weight: .heavy))
                .tracking(3)
                .foregroundColor(.secondary)
            
            Text("\(apiServer.apiTranscriptionCount)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
    }
    
    private var apiInfoView: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                // Left icon
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                
                // Center text
                Text("API Server")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                
                Spacer(minLength: 8)
                
                // Status indicator
                Circle()
                    .fill(apiServer.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                
                Text(apiServer.isRunning ? "Running" : "Stopped")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(apiGradient)
            .cornerRadius(10)
            
            if apiServer.isRunning {
                Text("Port: \(apiServer.port)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: 200)
    }
    
    private var apiGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.blue,
                Color.blue.opacity(0.7)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    // MARK: - Utility Methods
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
}

// MARK: - Helper Struct

struct APITimeBlockView: View {
    let duration: TimeInterval
    let label: String
    let icon: String
    let color: Color
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? ""
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(formatDuration(duration))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                
                Text(label)
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(color.opacity(0.1))
        )
    }
}

//#Preview {
//    APITranscriptionStatsView()
//        .environmentObject({
//            // Preview data would go here
//        }())
//        .padding()
//}