import Foundation

extension Transcription {
    var preferredHistoryText: String {
        guard let enhancedText, !enhancedText.isEmpty else { return text }
        return enhancedText
    }

    var hasEnhancedHistoryText: Bool {
        enhancedText?.isEmpty == false
    }

    var availableHistoryAudioURL: URL? {
        guard let audioFileURL,
            let url = URL(string: audioFileURL),
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    var recordedHistoryModeIcon: ModeIcon? {
        guard let modeEmoji else { return nil }
        let value = modeEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.isValidEmoji ? .emoji(value) : .symbol(value)
    }
}
