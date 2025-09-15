import SwiftUI

struct APIProcessingIndicator: View {
    let processingInfo: String
    let onStop: (() -> Void)?
    @State private var animationRotation: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Animated spinner
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.blue)
                .rotationEffect(.degrees(animationRotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                        animationRotation = 360
                    }
                }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("API Transcription in Progress")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text(processingInfo)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Stop button (if callback provided)
            if let onStop = onStop {
                Button(action: onStop) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Force stop stuck transcription")
            }
            
            // Pulse indicator
            Circle()
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .scaleEffect(animationRotation > 180 ? 1.2 : 0.8)
                .opacity(animationRotation > 180 ? 0.8 : 0.4)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: animationRotation)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.05))
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

#Preview {
    VStack(spacing: 20) {
        APIProcessingIndicator(processingInfo: "Processing 2.3 MB audio file...", onStop: nil)
        
        APIProcessingIndicator(processingInfo: "Processing large audio file (15.7 MB)...", onStop: {
            print("Stop button tapped")
        })
    }
    .padding()
    .background(Color(.controlBackgroundColor))
}