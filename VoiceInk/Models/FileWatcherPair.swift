import Foundation
import SwiftData

@Model
final class FileWatcherPair {
    var id: UUID
    var inputFolderPath: String
    var outputFolderPath: String
    var isEnabled: Bool
    var createdAt: Date

    init(inputFolderPath: String, outputFolderPath: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.inputFolderPath = inputFolderPath
        self.outputFolderPath = outputFolderPath
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }

    var inputFolderURL: URL {
        URL(fileURLWithPath: inputFolderPath)
    }

    var outputFolderURL: URL {
        URL(fileURLWithPath: outputFolderPath)
    }

    var isValid: Bool {
        let inputExists = FileManager.default.fileExists(atPath: inputFolderPath)
        let outputExists = FileManager.default.fileExists(atPath: outputFolderPath)
        return inputExists && outputExists
    }
}