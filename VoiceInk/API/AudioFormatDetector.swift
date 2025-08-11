import Foundation

/// Detects audio format from file data by examining file headers
struct AudioFormatDetector {
    
    enum AudioFormat: String {
        case mp3 = "mp3"
        case wav = "wav"
        case m4a = "m4a"
        case aac = "aac"
        case flac = "flac"
        case ogg = "ogg"
        case unknown = "bin"
        
        var contentType: String {
            switch self {
            case .mp3: return "audio/mpeg"
            case .wav: return "audio/wav"
            case .m4a: return "audio/mp4"
            case .aac: return "audio/aac"
            case .flac: return "audio/flac"
            case .ogg: return "audio/ogg"
            case .unknown: return "application/octet-stream"
            }
        }
    }
    
    /// Detect audio format from the first few bytes of the file data
    static func detectFormat(from data: Data) -> AudioFormat {
        guard data.count >= 12 else { return .unknown }
        
        let bytes = [UInt8](data.prefix(12))
        
        // MP3: Check for ID3 tag or MPEG sync bits
        if bytes.starts(with: [0x49, 0x44, 0x33]) {  // "ID3"
            return .mp3
        }
        if bytes.count >= 2 && (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {  // MPEG sync
            return .mp3
        }
        
        // WAV: Check for RIFF header
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) &&  // "RIFF"
           bytes[8...11] == [0x57, 0x41, 0x56, 0x45] {      // "WAVE"
            return .wav
        }
        
        // M4A/MP4: Check for ftyp box
        if bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {  // "ftyp"
            if bytes[8...11] == [0x4D, 0x34, 0x41, 0x20] {  // "M4A "
                return .m4a
            }
            // Could be AAC in MP4 container
            return .m4a
        }
        
        // FLAC: Check for magic number
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {  // "fLaC"
            return .flac
        }
        
        // OGG: Check for OggS header
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {  // "OggS"
            return .ogg
        }
        
        return .unknown
    }
    
    /// Detect format from Content-Type header if available
    static func detectFormat(from contentType: String?) -> AudioFormat? {
        guard let contentType = contentType?.lowercased() else { return nil }
        
        if contentType.contains("mpeg") || contentType.contains("mp3") {
            return .mp3
        }
        if contentType.contains("wav") || contentType.contains("wave") {
            return .wav
        }
        if contentType.contains("mp4") || contentType.contains("m4a") {
            return .m4a
        }
        if contentType.contains("aac") {
            return .aac
        }
        if contentType.contains("flac") {
            return .flac
        }
        if contentType.contains("ogg") {
            return .ogg
        }
        
        return nil
    }
    
    /// Extract Content-Type from multipart headers
    static func extractContentType(from headers: String) -> String? {
        let lines = headers.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-type:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }
}