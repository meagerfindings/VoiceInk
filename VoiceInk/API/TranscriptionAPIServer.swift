import Foundation
import Network
import SwiftData
import Combine
import os

// MARK: - Voice Recording Notifications

extension NSNotification.Name {
    static let voiceRecordingWillStart = NSNotification.Name("VoiceRecordingWillStart")
    static let voiceRecordingDidFinish = NSNotification.Name("VoiceRecordingDidFinish")
}

// MARK: - Error Types

enum APITranscriptionError: Error {
    case timeout
    case duplicateRequest
    case processingFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .timeout:
            return "Transcription timed out after 8 minutes"
        case .duplicateRequest:
            return "Request already in progress"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

struct TimeoutError: Error {
    let duration: TimeInterval
}

// MARK: - Timeout Helper

func withThrowingTimeout<T>(of duration: Duration, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Add the actual operation task
        group.addTask {
            do {
                return try await operation()
            } catch {
                // Re-throw the error but ensure we can distinguish cancellation
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }

        // Add the timeout task
        group.addTask {
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(duration: seconds)
        }

        // Wait for first task to complete
        guard let result = try await group.next() else {
            group.cancelAll()
            throw TimeoutError(duration: Double(duration.components.seconds))
        }

        // Cancel all remaining tasks (timeout or operation, whichever didn't complete)
        group.cancelAll()
        return result
    }
}

// MARK: - Supporting Classes

/* OLD NetworkManager implementation - replaced with WorkingHTTPServer
// Protocol for network manager to communicate with UI coordinator
protocol NetworkManagerDelegate: AnyObject {
    func networkManager(_ manager: NetworkManager, didChangeState isRunning: Bool)
    func networkManager(_ manager: NetworkManager, didEncounterError error: String)
    func networkManager(_ manager: NetworkManager, didProcessRequest stats: RequestStats)
}
*/

// Shared request stats structure
struct RequestStats {
    let method: String
    let path: String
    let processingTime: TimeInterval
    let success: Bool
}

/* OLD NetworkManager implementation - replaced with WorkingHTTPServer
/// Pure network handling class - NO MainActor isolation
class NetworkManager {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "NetworkManager")
    
    weak var delegate: NetworkManagerDelegate?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.voiceink.api.network", qos: .userInitiated)
    
    // Configuration
    private let port: Int
    private let allowNetworkAccess: Bool
    
    // Dependencies
    private let transcriptionProcessor: TranscriptionProcessor
    
    init(port: Int, allowNetworkAccess: Bool, transcriptionProcessor: TranscriptionProcessor) {
        self.port = port
        self.allowNetworkAccess = allowNetworkAccess
        self.transcriptionProcessor = transcriptionProcessor
    }
    
    func start() {
        guard listener == nil else { return }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        // Configure host binding
        let host = allowNetworkAccess ? nil : NWEndpoint.Host("127.0.0.1")
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            
            if let host = host {
                listener?.parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleStateUpdate(state)
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: queue)
            logger.info("Network manager starting on port \(self.port)")
            
        } catch {
            logger.error("Failed to start network manager: \(error.localizedDescription)")
            notifyDelegate { delegate in
                delegate.networkManager(self, didEncounterError: error.localizedDescription)
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        logger.info("Network manager stopped")
        
        notifyDelegate { delegate in
            delegate.networkManager(self, didChangeState: false)
        }
    }
    
    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("Network manager is ready on port \(self.port)")
            notifyDelegate { delegate in
                delegate.networkManager(self, didChangeState: true)
            }
        case .failed(let error):
            logger.error("Network manager failed: \(error.localizedDescription)")
            notifyDelegate { delegate in
                delegate.networkManager(self, didEncounterError: error.localizedDescription)
                delegate.networkManager(self, didChangeState: false)
            }
        case .cancelled:
            logger.info("Network manager cancelled")
            notifyDelegate { delegate in
                delegate.networkManager(self, didChangeState: false)
            }
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        logger.debug("🟢 NEW CONNECTION: Connection received from \(connection.endpoint)")
        
        // Start connection on background queue
        connection.start(queue: queue)
        logger.debug("🟢 NEW CONNECTION: Connection started on background queue")
        
        // Create connection handler
        let connectionHandler = ConnectionHandler(
            connection: connection, 
            transcriptionProcessor: transcriptionProcessor,
            networkManager: self
        )
        logger.debug("🟢 NEW CONNECTION: ConnectionHandler created, starting to read...")
        connectionHandler.startReading()
        logger.debug("🟢 NEW CONNECTION: startReading() called")
    }
    
    // Helper to safely notify delegate on MainActor
    private func notifyDelegate(_ action: @escaping (NetworkManagerDelegate) -> Void) {
        guard let delegate = delegate else { return }
        
        Task { @MainActor in
            action(delegate)
        }
    }
    
    // Method for connection handlers to report request completion
    func reportRequestCompletion(_ stats: RequestStats) {
        notifyDelegate { delegate in
            delegate.networkManager(self, didProcessRequest: stats)
        }
    }
}

/// Handles individual connection data accumulation and processing
/// NOT @MainActor - runs on background queues
class ConnectionHandler {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "ConnectionHandler")
    
    private let connection: NWConnection
    private let transcriptionProcessor: TranscriptionProcessor
    private weak var networkManager: NetworkManager?
    
    private var accumulatedData = Data()
    private var expectedContentLength: Int?
    private var headerEndIndex: Int?
    private let maxBufferSize = 524288000 // 500MB
    private var isRequestProcessed = false // Prevent duplicate processing
    
    // Debug tracking
    private let connectionId: String
    private let startTime: Date
    private var timeoutTimer: Timer?
    
    init(connection: NWConnection, transcriptionProcessor: TranscriptionProcessor, networkManager: NetworkManager) {
        self.connection = connection
        self.transcriptionProcessor = transcriptionProcessor
        self.networkManager = networkManager
        self.connectionId = String(UUID().uuidString.prefix(8))
        self.startTime = Date()
        
        print("🟢 NEW CONNECTION: CONN-\(connectionId) received at \(startTime)")
        logger.debug("🔷 CONN-\(connectionId): ConnectionHandler initialized")
    }
    
    func startReading() {
        print("🟢 NEW CONNECTION: CONN-\(connectionId) starting on background queue")
        logger.debug("🔵 CONN-\(connectionId): Beginning data reading loop")
        
        // Set up timeout timer (30 seconds)
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("🔴 TIMEOUT: CONN-\(self.connectionId) hung for 30 seconds! Last state: processed=\(self.isRequestProcessed)")
            self.connection.cancel()
        }
        
        readNextChunk()
    }
    
    private func handleTimeout() {
        let elapsed = Date().timeIntervalSince(startTime)
        logger.error("⏰ CONN-\(connectionId): TIMEOUT after \(String(format: "%.1f", elapsed))s - accumulated: \(accumulatedData.count) bytes, processed: \(isRequestProcessed)")
        connection.cancel()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
    
    private func cleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let elapsed = Date().timeIntervalSince(startTime)
        logger.debug("🧹 CONN-\(connectionId): Cleanup after \(String(format: "%.1f", elapsed))s")
    }
    
    private func readNextChunk() {
        logger.debug("🔵 CONN-\(connectionId): Calling connection.receive()")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { 
                print("🔴 READ CHUNK: Self is nil, returning")
                return 
            }
            
            self.logger.debug("🔵 CONN-\(self.connectionId): Received callback - data: \(data?.count ?? 0) bytes, isComplete: \(isComplete), error: \(error?.localizedDescription ?? "none")")
            
            if let error = error {
                self.logger.error("🔴 CONN-\(self.connectionId): Connection error: \(error.localizedDescription)")
                self.cleanup()
                self.connection.cancel()
                return
            }
            
            // Append any received data
            if let data = data {
                self.logger.debug("🔵 READ CHUNK: Appending \(data.count) bytes. Total so far: \(self.accumulatedData.count + data.count) bytes")
                self.accumulatedData.append(data)
                
                // Check if buffer is too large
                if self.accumulatedData.count > self.maxBufferSize {
                    self.logger.error("🔴 CONN-\(self.connectionId): Request too large: \(self.accumulatedData.count) bytes")
                    self.sendErrorResponse(statusCode: 413, message: "Request Entity Too Large")
                    return
                }
                
                // Try to parse headers if we haven't yet
                if self.headerEndIndex == nil {
                    self.logger.debug("🟡 HEADER PARSE: Looking for header separator in \(self.accumulatedData.count) bytes")
                    if let separator = "\r\n\r\n".data(using: .utf8),
                       let range = self.accumulatedData.range(of: separator) {
                        self.logger.debug("🟡 HEADER PARSE: Found header separator at range \(range)")
                        self.headerEndIndex = range.upperBound
                        
                        // Parse Content-Length from headers
                        let headerData = self.accumulatedData.subdata(in: 0..<range.lowerBound)
                        if let headers = String(data: headerData, encoding: .utf8) {
                            self.logger.debug("🟡 HEADER PARSE: Headers parsed - \(headers.components(separatedBy: "\r\n")[0])")
                            self.parseContentLength(from: headers)
                            
                            // For GET requests with no body, process immediately
                            if headers.contains("GET /health") && !self.isRequestProcessed {
                                self.logger.debug("🟢 ROUTE: Processing GET /health request")
                                self.isRequestProcessed = true
                                self.processHealthRequest()
                                return
                            } else if headers.contains("GET /debug") && !self.isRequestProcessed {
                                self.logger.debug("🟢 ROUTE: Processing GET /debug request")
                                self.isRequestProcessed = true
                                self.processDebugRequest()
                                return
                            } else if headers.contains("GET ") && !self.isRequestProcessed {
                                self.logger.debug("🟢 ROUTE: Processing GET request")
                                self.isRequestProcessed = true
                                self.processRequest()
                                return
                            }
                        }
                    }
                }
                
                // Check if we have received all expected data
                if let expectedLength = self.expectedContentLength,
                   let headerEnd = self.headerEndIndex {
                    let currentBodyLength = self.accumulatedData.count - headerEnd
                    self.logger.debug("🟡 BODY CHECK: Expected \(expectedLength) bytes, have \(currentBodyLength) bytes")
                    
                    if currentBodyLength >= expectedLength && !self.isRequestProcessed {
                        // We have all the data, process it
                        self.logger.info("🟢 COMPLETE: Complete request received: \(self.accumulatedData.count) bytes total")
                        self.isRequestProcessed = true
                        self.processRequest()
                        return
                    }
                }
            }
            
            // Continue reading if not complete
            if !isComplete {
                self.logger.debug("🔵 CONN-\(self.connectionId): Connection not complete, continuing to read...")
                self.readNextChunk()
            } else {
                self.logger.debug("🟠 CONN-\(self.connectionId): Connection marked complete")
                // Connection completed - process what we have
                if self.accumulatedData.count > 0 && !self.isRequestProcessed {
                    self.logger.debug("🟢 CONN-\(self.connectionId): Processing remaining data (\(self.accumulatedData.count) bytes)")
                    self.isRequestProcessed = true
                    self.processRequest()
                } else {
                    self.logger.error("🔴 CONN-\(self.connectionId): Connection closed with no data")
                    self.cleanup()
                    self.connection.cancel()
                }
            }
        }
    }
    
    private func parseContentLength(from headers: String) {
        let lines = headers.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let lengthStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    self.expectedContentLength = Int(lengthStr)
                    logger.debug("🟡 CONTENT-LENGTH: Parsed Content-Length: \(self.expectedContentLength ?? 0)")
                    break
                }
            }
        }
        if expectedContentLength == nil {
            logger.debug("🟡 CONTENT-LENGTH: No Content-Length header found")
        }
    }
    
    private func processHealthRequest() {
        logger.debug("🟢 HEALTH: Starting health request processing")
        let startTime = Date()
        
        // Create simple health JSON string to avoid Content-Length miscalculation
        let healthJson = "{\"status\":\"healthy\",\"service\":\"VoiceInk API\",\"timestamp\":\(Date().timeIntervalSince1970)}"
        
        // Build complete HTTP response with correct Content-Length
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(healthJson.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(healthJson)"
        
        let responseData = response.data(using: .utf8) ?? Data()
        
        logger.debug("🟢 HEALTH: Sending health response: \(response.count) bytes")
        logger.debug("🟢 HEALTH: Response content: \(response.prefix(200))...")
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("🔴 CONN-\(self?.connectionId ?? "?"): Health response send error: \(error)")
            } else {
                self?.logger.debug("✅ CONN-\(self?.connectionId ?? "?"): Health response sent successfully")
            }
            
            // Report completion stats
            let processingTime = Date().timeIntervalSince(startTime)
            let stats = RequestStats(method: "GET", path: "/health", processingTime: processingTime, success: error == nil)
            self?.networkManager?.reportRequestCompletion(stats)
            
            // Immediate connection close
            self?.logger.debug("🟢 CONN-\(self?.connectionId ?? "?"): Cancelling connection")
            self?.cleanup()
            self?.connection.cancel()
        })
    }
    
    private func processDebugRequest() {
        logger.debug("🔧 DEBUG: Starting minimal debug request processing")
        let startTime = Date()
        
        let debugJson = "{\"debug\":\"minimal\",\"timestamp\":\(Date().timeIntervalSince1970),\"connection_id\":\"\(UUID().uuidString.prefix(8))\"}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(debugJson.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(debugJson)"
        let responseData = response.data(using: .utf8) ?? Data()
        
        logger.debug("🔧 DEBUG: Calling connection.send() with \(responseData.count) bytes")
        logger.debug("🔧 DEBUG: Response: \(response.replacingOccurrences(of: "\r\n", with: " | "))")
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            self?.logger.debug("🔧 CONN-\(self?.connectionId ?? "?"): Send completion handler called")
            if let error = error {
                self?.logger.error("🔴 CONN-\(self?.connectionId ?? "?"): Send error: \(error)")
            } else {
                self?.logger.debug("✅ CONN-\(self?.connectionId ?? "?"): Send successful")
            }
            
            let processingTime = Date().timeIntervalSince(startTime)
            let stats = RequestStats(method: "GET", path: "/debug", processingTime: processingTime, success: error == nil)
            self?.networkManager?.reportRequestCompletion(stats)
            
            self?.logger.debug("🔧 CONN-\(self?.connectionId ?? "?"): Calling connection.cancel()")
            self?.cleanup()
            self?.connection.cancel()
            self?.logger.debug("🔧 CONN-\(self?.connectionId ?? "?"): Connection cancelled")
        })
        logger.debug("🔧 DEBUG: connection.send() returned, waiting for completion handler...")
    }
    
    private func processRequest() {
        logger.debug("🟢 PROCESS: Starting request processing")
        let startTime = Date()
        
        // Find the header/body separator
        let separator = "\r\n\r\n".data(using: .utf8)!
        guard let separatorRange = accumulatedData.range(of: separator) else {
            logger.error("🔴 PROCESS: No header/body separator found in \(accumulatedData.count) bytes")
            sendErrorResponse(statusCode: 400, message: "Invalid request")
            return
        }
        logger.debug("🟢 PROCESS: Found separator at range \(separatorRange)")
        
        // Parse headers as UTF-8
        let headerData = accumulatedData.subdata(in: 0..<separatorRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            logger.error("Cannot parse headers")
            sendErrorResponse(statusCode: 400, message: "Invalid request headers")
            return
        }
        
        // Parse HTTP request line
        let lines = headers.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendErrorResponse(statusCode: 400, message: "Invalid request")
            return
        }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(statusCode: 400, message: "Invalid request")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        
        logger.info("🟢 PROCESS: Request: \(method) \(path)")
        logger.debug("🟢 PROCESS: Full request line: \(firstLine)")
        
        // Extract body data
        let bodyStart = separatorRange.upperBound
        let bodyData = accumulatedData.subdata(in: bodyStart..<accumulatedData.count)
        
        // Route the request (health requests already handled in readNextChunk)
        logger.debug("🟢 PROCESS: Creating Task for request processing")
        Task {
            do {
                if method == "POST" && path == "/api/transcribe" {
                    self.logger.debug("🟢 ROUTE: Routing to handleTranscribeRequest")
                    try await self.handleTranscribeRequest(headers: headers, bodyData: bodyData, startTime: startTime)
                } else {
                    self.logger.error("🔴 ROUTE: Path not found: \(path)")
                    self.sendErrorResponse(statusCode: 404, message: "Not found")
                    
                    let processingTime = Date().timeIntervalSince(startTime)
                    let stats = RequestStats(method: method, path: path, processingTime: processingTime, success: false)
                    self.networkManager?.reportRequestCompletion(stats)
                }
            } catch {
                self.logger.error("🔴 PROCESS: Request processing failed: \(error.localizedDescription)")
                self.sendErrorResponse(statusCode: 500, message: error.localizedDescription)
                
                let processingTime = Date().timeIntervalSince(startTime)
                let stats = RequestStats(method: method, path: path, processingTime: processingTime, success: false)
                self.networkManager?.reportRequestCompletion(stats)
            }
        }
        logger.debug("🟢 PROCESS: Task created and dispatched")
    }
    
    private func handleTranscribeRequest(headers: String, bodyData: Data, startTime: Date) async throws {
        logger.debug("🟣 TRANSCRIBE: Starting transcription request handler")
        // Extract the multipart boundary
        guard let boundary = extractBoundary(from: headers) else {
            logger.error("🔴 TRANSCRIBE: Missing multipart boundary")
            sendErrorResponse(statusCode: 400, message: "Missing multipart boundary")
            return
        }
        logger.debug("🟣 TRANSCRIBE: Found boundary: \(boundary)")
        
        // Parse multipart data from raw body
        logger.debug("🟣 TRANSCRIBE: Extracting audio data from \(bodyData.count) bytes")
        guard let audioData = extractAudioDataFromRaw(bodyData: bodyData, boundary: boundary) else {
            logger.error("🔴 TRANSCRIBE: Failed to extract audio data from multipart. Body size: \(bodyData.count) bytes, Boundary: \(boundary)")
            sendErrorResponse(statusCode: 400, message: "No audio file found. Body size: \(bodyData.count) bytes")
            return
        }
        logger.debug("🟣 TRANSCRIBE: Successfully extracted \(audioData.count) bytes of audio data")
        
        logger.info("🟣 TRANSCRIBE: Successfully extracted audio data: \(audioData.count) bytes")
        
        // Process the transcription using the transcription processor
        logger.debug("🟣 TRANSCRIBE: Calling transcriptionProcessor.transcribe()")
        let result = try await transcriptionProcessor.transcribe(audioData: audioData)
        let processingTime = Date().timeIntervalSince(startTime)
        logger.debug("🟣 TRANSCRIBE: Transcription completed, got \(result.count) bytes of response")
        
        // Send response
        logger.debug("🟣 TRANSCRIBE: Sending JSON response")
        sendJSONResponse(data: result)
        
        // Report completion stats
        let stats = RequestStats(method: "POST", path: "/api/transcribe", processingTime: processingTime, success: true)
        networkManager?.reportRequestCompletion(stats)
    }
    
    private func extractBoundary(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().contains("content-type:") && line.contains("boundary=") {
                let parts = line.components(separatedBy: "boundary=")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }
    
    private func extractAudioDataFromRaw(bodyData: Data, boundary: String) -> Data? {
        // Parse multipart data without converting to string
        let boundaryData = "--\(boundary)".data(using: .utf8)!
        let headerSeparator = "\r\n\r\n".data(using: .utf8)!
        let endBoundary = "--\(boundary)--".data(using: .utf8)!
        
        // Split by boundary
        var currentIndex = 0
        while currentIndex < bodyData.count {
            // Find next boundary
            guard let boundaryRange = bodyData.range(of: boundaryData, in: currentIndex..<bodyData.count) else {
                break
            }
            
            // Find header separator after boundary
            let partStart = boundaryRange.upperBound
            guard let headerEndRange = bodyData.range(of: headerSeparator, in: partStart..<bodyData.count) else {
                currentIndex = partStart
                continue
            }
            
            // Extract headers
            let headerData = bodyData.subdata(in: partStart..<headerEndRange.lowerBound)
            guard let headers = String(data: headerData, encoding: .utf8) else {
                currentIndex = headerEndRange.upperBound
                continue
            }
            
            // Check if this is the file field
            if headers.contains("Content-Disposition: form-data") && headers.contains("name=\"file\"") {
                // Find the end of this part
                let dataStart = headerEndRange.upperBound
                
                // Look for next boundary or end boundary
                var dataEnd = bodyData.count
                if let nextBoundaryRange = bodyData.range(of: boundaryData, in: dataStart..<bodyData.count) {
                    // Back up to remove the \r\n before boundary
                    dataEnd = nextBoundaryRange.lowerBound
                    if dataEnd >= 2 {
                        dataEnd -= 2  // Remove \r\n
                    }
                } else if let endRange = bodyData.range(of: endBoundary, in: dataStart..<bodyData.count) {
                    dataEnd = endRange.lowerBound
                    if dataEnd >= 2 {
                        dataEnd -= 2  // Remove \r\n
                    }
                }
                
                // Extract audio data
                return bodyData.subdata(in: dataStart..<dataEnd)
            }
            
            currentIndex = headerEndRange.upperBound
        }
        
        return nil
    }
    
    private func sendJSONResponse(data: Data) {
        logger.debug("📤 SEND: Preparing JSON response with \(data.count) bytes of data")
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(data)
        
        logger.debug("📤 SEND: Sending total \(responseData.count) bytes (\(response.data(using: .utf8)?.count ?? 0) header + \(data.count) body)")
        logger.debug("📤 SEND: HTTP headers: \(response.replacingOccurrences(of: "\r\n", with: " | "))")
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("🔴 CONN-\(self?.connectionId ?? "?"): JSON response send error: \(error)")
            } else {
                self?.logger.debug("✅ CONN-\(self?.connectionId ?? "?"): JSON response sent successfully")
            }
            self?.logger.debug("📤 CONN-\(self?.connectionId ?? "?"): Cancelling connection")
            self?.cleanup()
            self?.connection.cancel()
        })
    }
    
    private func sendErrorResponse(statusCode: Int, message: String) {
        logger.debug("📤 ERROR: Sending error response: \(statusCode) - \(message)")
        let json = """
        {"success":false,"error":{"code":"\(statusCode)","message":"\(message)"}}
        """
        
        let statusText = statusCode == 404 ? "Not Found" : 
                        statusCode == 400 ? "Bad Request" :
                        statusCode == 500 ? "Internal Server Error" :
                        statusCode == 413 ? "Payload Too Large" : "Error"
        
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(json)"
        
        logger.debug("📤 ERROR: Sending \(response.count) bytes")
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("🔴 CONN-\(self?.connectionId ?? "?"): Error response send error: \(error)")
            } else {
                self?.logger.debug("✅ CONN-\(self?.connectionId ?? "?"): Error response sent successfully")
            }
            self?.logger.debug("📤 CONN-\(self?.connectionId ?? "?"): Cancelling connection")
            self?.cleanup()
            self?.connection.cancel()
        })
    }
}
*/ // END OLD NetworkManager implementation

/// Handles transcription processing on background queues
/// NOT @MainActor - accesses WhisperState using await MainActor.run
class TranscriptionProcessor {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "TranscriptionProcessor")
    
    private let whisperState: WhisperState
    let apiHandler: TranscriptionAPIHandler // Made public for API server to access
    weak var apiServer: TranscriptionAPIServer?
    
    init(whisperState: WhisperState, modelContext: ModelContext) {
        self.whisperState = whisperState
        self.apiHandler = TranscriptionAPIHandler(whisperState: whisperState, modelContext: modelContext)
    }
    
    /// Request immediate abort of any in-flight transcription
    func requestAbortNow() async {
        await MainActor.run {
            _ = Task {
                if let whisperContext = await whisperState.whisperContext {
                    await whisperContext.requestAbortNow()
                }
            }
        }
    }
    
    /// Transcribe audio data - runs on background queue, safely accesses MainActor state
    func transcribe(audioData: Data, filename: String? = nil) async throws -> Data {
        logger.info("Starting transcription of \(audioData.count) bytes, filename: \(filename ?? "none")")

        // Calculate file size for display
        let fileSizeMB = Double(audioData.count) / 1024 / 1024
        let fileSizeInfo = String(format: "%.1f MB", fileSizeMB)

        // Update progress if we have a current processing request
        if let currentRequest = await MainActor.run(body: { apiServer?.currentProcessingRequest }) {
            let progressInfo: String
            if let filename = filename {
                progressInfo = "Processing \(filename) (\(fileSizeInfo))"
            } else {
                progressInfo = "Processing \(fileSizeInfo) audio file..."
            }

            await MainActor.run {
                currentRequest.updateProgress(0.2, info: progressInfo)
            }
        }

        do {
            // Use withThrowingTimeout for a higher ceiling to accommodate longer files
            let result = try await withThrowingTimeout(of: .seconds(1200)) { [self] in
                try await apiHandler.transcribe(audioData: audioData, filename: filename)
            }

            logger.info("✅ Transcription completed successfully, result size: \(result.count) bytes")
            return result
        } catch {
            if error is TimeoutError {
                logger.error("⏰ Transcription timed out after 20 minutes for: \(filename ?? "unknown")")
                throw APITranscriptionError.timeout
            }

            logger.error("🔴 Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Pause Policy

/// Reasons why API transcription queue processing might be paused
enum PauseReason: String, CaseIterable, Hashable {
    case manual = "manual"
    case voiceRecording = "voiceRecording"
    case onBattery = "onBattery"
    
    var displayName: String {
        switch self {
        case .manual:
            return "Manual"
        case .voiceRecording:
            return "Voice recording"
        case .onBattery:
            return "Battery"
        }
    }
}

// MARK: - Main API Server Coordinator

/// API Server Coordinator - MainActor for UI state management only
@MainActor
class TranscriptionAPIServer: ObservableObject, WorkingHTTPServerDelegate {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APICoordinator")
    
    @Published var isRunning = false
    @Published var port: Int = 5000
    @Published var lastError: String?
    
    // API transcription queue and processing tracking
    @Published var activeTranscriptions: [APITranscriptionRequest] = []
    @Published var transcriptionQueue: [APITranscriptionRequest] = []
    @Published var currentProcessingRequest: APITranscriptionRequest?
    
    // Pause policy state
    @Published private var pauseReasons: Set<PauseReason> = []
    @Published var batteryOverrideProcessOnBattery = false {
        didSet {
            UserDefaults.standard.set(batteryOverrideProcessOnBattery, forKey: "APIServerProcessOnBattery")
            logger.info("Battery override updated: \(self.batteryOverrideProcessOnBattery)")
            if batteryOverrideProcessOnBattery && pauseReasons.contains(.onBattery) {
                resumeProcessingIfPossible()
            }
        }
    }

    // Legacy properties for backward compatibility (computed from new state)
    var isProcessingAPIRequest: Bool {
        return currentProcessingRequest != nil
    }

    var currentAPIRequestInfo: String? {
        return currentProcessingRequest?.processingInfo
    }
    
    // Computed pause state properties
    var isPausedEffective: Bool {
        let nonBatteryReasons = pauseReasons.subtracting([.onBattery])
        return !nonBatteryReasons.isEmpty || (pauseReasons.contains(.onBattery) && !batteryOverrideProcessOnBattery)
    }
    
    var pauseReasonsSummary: String {
        if pauseReasons.isEmpty {
            return ""
        }
        
        var activeReasons: [String] = []
        
        // Add non-battery reasons first
        for reason in pauseReasons {
            if reason != .onBattery {
                activeReasons.append(reason.displayName)
            }
        }
        
        // Add battery reason only if override is false
        if pauseReasons.contains(.onBattery) && !batteryOverrideProcessOnBattery {
            activeReasons.append(PauseReason.onBattery.displayName)
        }
        
        return activeReasons.joined(separator: ", ")
    }
    
    // Power state access for UI
    var isOnBattery: Bool {
        return powerModeService.isOnBattery
    }
    
    var batteryPercent: Double {
        return powerModeService.batteryPercent
    }
    
    var powerSourceDescription: String {
        return powerModeService.powerSourceDescription
    }
    
    // API statistics tracking
    @Published var apiTranscriptionCount: Int = 0
    @Published var totalAudioDuration: TimeInterval = 0
    @Published var totalAPIProcessingTime: TimeInterval = 0
    
    // Request deduplication tracking with timestamps for expiration
    private var activeRequests: [String: Date] = [:]
    private let requestExpirationTime: TimeInterval = 1800 // 30 minutes
    
    // Network handling - runs on background queues
    private var httpServer: WorkingHTTPServer?
    private let transcriptionProcessor: TranscriptionProcessor
    let whisperState: WhisperState
    
    // Power monitoring service
    private let powerModeService = PowerModeService()
    private var cancellables = Set<AnyCancellable>()
    
    // Thread safety guard for processNextInQueue
    private var isProcessingNext = false
    
    // Stats tracking
    private var serverStartTime: Date?
    private var requestCount: Int = 0
    private var totalProcessingTime: TimeInterval = 0
    
    init(whisperState: WhisperState, modelContext: ModelContext) {
        self.whisperState = whisperState
        self.transcriptionProcessor = TranscriptionProcessor(whisperState: whisperState, modelContext: modelContext)
        
        // Load saved settings
        self.port = UserDefaults.standard.integer(forKey: "APIServerPort")
        if self.port == 0 {
            self.port = 5000
        }
        
        // Load API statistics from database
        loadAPIStatisticsFromDatabase(modelContext: modelContext)
        
        // Load pause settings from UserDefaults
        batteryOverrideProcessOnBattery = UserDefaults.standard.bool(forKey: "APIServerProcessOnBattery")
        
        // Load manual pause state
        if UserDefaults.standard.bool(forKey: "APIServerManualPause") {
            pauseReasons.insert(.manual)
            logger.info("🔄 Restored manual pause state from UserDefaults")
        }
        
        // Listen for auto-dismiss notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAutoDismissNotification(_:)),
            name: .apiTranscriptionAutoDismiss,
            object: nil
        )
        
        // Listen for voice recording events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVoiceRecordingWillStart(_:)),
            name: .voiceRecordingWillStart,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVoiceRecordingDidFinish(_:)),
            name: .voiceRecordingDidFinish,
            object: nil
        )
        
        // Set up power monitoring and battery pause integration
        setupPowerMonitoring()
    }
    
    // MARK: - Pause Management
    
    /// Set manual pause state
    func setManualPaused(_ paused: Bool) {
        if paused {
            pauseReasons.insert(.manual)
            UserDefaults.standard.set(true, forKey: "APIServerManualPause")
            logger.info("🔴 Manual pause enabled")
        } else {
            pauseReasons.remove(.manual)
            UserDefaults.standard.set(false, forKey: "APIServerManualPause")
            logger.info("🟢 Manual pause disabled")
            resumeProcessingIfPossible()
        }
        updateQueueInfo() // Update queue display immediately
    }
    
    /// Set voice recording priority pause state
    func setVoicePriorityPaused(_ paused: Bool) {
        if paused {
            pauseReasons.insert(.voiceRecording)
            logger.info("🔴 Voice recording pause enabled")
        } else {
            pauseReasons.remove(.voiceRecording)
            logger.info("🟢 Voice recording pause disabled")
            resumeProcessingIfPossible()
        }
        updateQueueInfo() // Update queue display immediately
    }
    
    /// Set battery pause state
    func setBatteryPaused(isOnBattery: Bool) {
        if isOnBattery {
            pauseReasons.insert(.onBattery)
            logger.info("🔴 Battery pause enabled (override: \(self.batteryOverrideProcessOnBattery))")
        } else {
            pauseReasons.remove(.onBattery)
            logger.info("🟢 Battery pause disabled (on AC power)")
            resumeProcessingIfPossible()
        }
        updateQueueInfo() // Update queue display immediately
    }
    
    /// Resume processing if conditions allow
    private func resumeProcessingIfPossible() {
        guard !isPausedEffective else {
            logger.debug("Cannot resume - still paused: \(self.pauseReasonsSummary)")
            return
        }
        
        logger.info("🟢 Resuming API transcription processing")
        processNextInQueue()
    }
    
    /// Set up power monitoring and battery pause integration
    private func setupPowerMonitoring() {
        // Monitor power source changes
        powerModeService.$isOnBattery
            .removeDuplicates()
            .sink { [weak self] isOnBattery in
                Task { @MainActor in
                    self?.setBatteryPaused(isOnBattery: isOnBattery)
                }
            }
            .store(in: &cancellables)
        
        // Start monitoring immediately
        powerModeService.startMonitoring()
        
        // Set initial battery pause state based on current power source and override setting
        Task { @MainActor in
            // Give power monitoring a moment to get initial state
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            
            if powerModeService.isOnBattery && !batteryOverrideProcessOnBattery {
                pauseReasons.insert(.onBattery)
                updateQueueInfo()
                logger.info("⚡ Initial battery pause applied (on battery, override disabled)")
            }
        }
        
        logger.info("✅ Power monitoring integration setup complete")
    }
    
    func start() async {
        guard !isRunning else { return }

        serverStartTime = Date()
        requestCount = 0
        totalProcessingTime = 0

        // Ensure a model is loaded or selected BEFORE starting the HTTP server
        await ensureModelIsReady()

        // Connect processor to this API server for state tracking
        transcriptionProcessor.apiServer = self
        transcriptionProcessor.apiHandler.apiServer = self

        // Create and configure HTTP server
        let allowNetworkAccess = UserDefaults.standard.bool(forKey: "APIServerAllowNetworkAccess")
        httpServer = WorkingHTTPServer(
            port: port,
            allowNetworkAccess: allowNetworkAccess,
            transcriptionProcessor: transcriptionProcessor
        )
        httpServer?.delegate = self
        httpServer?.apiServer = self

        // Start HTTP server
        do {
            try httpServer?.start()
        } catch {
            logger.error("Failed to start HTTP server: \(error)")
            lastError = error.localizedDescription
        }

        logger.info("API server coordinator starting on port \(self.port)")
    }
    
    func stop() {
        httpServer?.stop()
        httpServer = nil
        powerModeService.stopMonitoring()
        cancellables.removeAll()
        isRunning = false
        logger.info("API server coordinator stopped")
    }
    
    private func ensureModelIsReady() async {
        let whisperState = self.whisperState
        
        // First, try to load the saved model preference
        whisperState.loadCurrentTranscriptionModel()
        
        // Check if a model is already selected
        if whisperState.currentTranscriptionModel != nil {
            logger.info("Model already selected: \(whisperState.currentTranscriptionModel?.displayName ?? "Unknown")")
            
            // If it's a local model and not loaded, try to load it
            if let model = whisperState.currentTranscriptionModel,
               model.provider == .local,
               !whisperState.isModelLoaded {
                
                // Ensure available models are loaded
                whisperState.loadAvailableModels()
                
                if let localModel = whisperState.availableModels.first(where: { $0.name == model.name }) {
                    do {
                        logger.info("Loading local model: \(model.displayName)")
                        try await whisperState.loadModel(localModel)
                        logger.info("Model loaded successfully")
                    } catch {
                        logger.error("Failed to load model: \(error.localizedDescription)")
                    }
                }
            }
            return
        }
        
        // No model selected, try to select a default one
        logger.info("No model selected, attempting to select default model")
        
        // First, check if there's a previously selected model in UserDefaults
        if let savedModelName = UserDefaults.standard.string(forKey: "CurrentTranscriptionModel") {
            
            // Load available models first
            whisperState.loadAvailableModels()
            
            // Check if it's a local model
            if let model = whisperState.availableModels.first(where: { $0.name == savedModelName }) {
                // Create a LocalModel instance
                let transcriptionModel = LocalModel(
                    name: model.name,
                    displayName: model.name.replacingOccurrences(of: "ggml-", with: ""),
                    size: "Unknown",
                    supportedLanguages: [:],
                    description: "Local Whisper model",
                    speed: 1.0,
                    accuracy: 1.0,
                    ramUsage: 0.0
                )
                whisperState.currentTranscriptionModel = transcriptionModel
                
                // Try to load the model
                do {
                    logger.info("Loading saved local model: \(model.name)")
                    try await whisperState.loadModel(model)
                    logger.info("Model loaded successfully")
                } catch {
                    logger.error("Failed to load saved model: \(error.localizedDescription)")
                }
                return
            } else {
                // It might be a cloud model - check in the predefined models
                if let cloudModel = whisperState.allAvailableModels.first(where: { $0.name == savedModelName }) {
                    whisperState.currentTranscriptionModel = cloudModel
                    logger.info("Selected saved model: \(savedModelName)")
                    return
                }
            }
        }
        
        // If no saved model or loading failed, try to select a default
        // Check for available local models
        whisperState.loadAvailableModels()
        if let firstModel = whisperState.availableModels.first {
            let transcriptionModel = LocalModel(
                name: firstModel.name,
                displayName: firstModel.name.replacingOccurrences(of: "ggml-", with: ""),
                size: "Unknown",
                supportedLanguages: [:],
                description: "Local Whisper model",
                speed: 1.0,
                accuracy: 1.0,
                ramUsage: 0.0
            )
            whisperState.currentTranscriptionModel = transcriptionModel
            
            do {
                logger.info("Loading default local model: \(firstModel.name)")
                try await whisperState.loadModel(firstModel)
                logger.info("Model loaded successfully")
            } catch {
                logger.error("Failed to load default model: \(error.localizedDescription)")
            }
        } else {
            // Fall back to cloud model if no local models available
            let defaultModel = CloudModel(
                name: "whisper-1",
                displayName: "Whisper",
                description: "OpenAI Whisper API",
                provider: .groq,  // Using Groq as default since OpenAI isn't in the enum
                speed: 1.0,
                accuracy: 1.0,
                isMultilingual: true,
                supportedLanguages: [:]
            )
            whisperState.currentTranscriptionModel = defaultModel
            logger.info("Selected default cloud model: whisper-1")
        }
    }
    
    // MARK: - WorkingHTTPServerDelegate
    
    nonisolated func httpServer(_ server: WorkingHTTPServer, didChangeState isRunning: Bool) {
        Task { @MainActor in
            self.isRunning = isRunning
            if isRunning {
                lastError = nil
                logger.info("API server is ready on port \(self.port)")
            } else {
                logger.info("API server stopped")
            }
        }
    }

    nonisolated func httpServer(_ server: WorkingHTTPServer, didEncounterError error: String) {
        Task { @MainActor in
            lastError = error
            logger.error("API server error: \(error)")
        }
    }

    nonisolated func httpServer(_ server: WorkingHTTPServer, didProcessRequest stats: RequestStats) {
        Task { @MainActor in
            requestCount += 1
            totalProcessingTime += stats.processingTime

            // Track API transcription statistics
            if stats.path == "/api/transcribe" && stats.success {
                apiTranscriptionCount += 1
                totalAPIProcessingTime += stats.processingTime
                // Note: audio duration will be updated when the transcription is saved to database
            }

            logger.info("Processed \(stats.method) \(stats.path) - \(stats.success ? "SUCCESS" : "FAILED") in \(String(format: "%.2f", stats.processingTime * 1000))ms")
        }
    }
    
    // Enhanced health status method for detailed API information
    private func getHealthStatus() async -> Data {
        // Get current model info
        let currentModel = await MainActor.run { whisperState.currentTranscriptionModel }
        let modelLoaded = await MainActor.run { whisperState.isModelLoaded }
        let availableModels = await MainActor.run { whisperState.availableModels.map { $0.name } }
        
        // Get system info
        let processInfo = ProcessInfo.processInfo
        let memoryUsage = getMemoryUsage()
        
        // Get API stats
        let uptime = Date().timeIntervalSince(serverStartTime ?? Date())
        
        let health = HealthResponse(
            status: "healthy",
            service: "VoiceInk API",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            timestamp: Date().timeIntervalSince1970,
            system: SystemInfo(
                platform: "macOS",
                osVersion: processInfo.operatingSystemVersionString,
                processorCount: processInfo.processorCount,
                memoryUsageMB: memoryUsage,
                uptimeSeconds: uptime,
                powerSource: powerModeService.powerSourceDescription.isEmpty ? nil : powerModeService.powerSourceDescription,
                isOnBattery: powerModeService.isOnBattery,
                batteryPercent: powerModeService.batteryPercent > 0 ? powerModeService.batteryPercent : nil
            ),
            api: APIInfo(
                endpoint: "http://\(UserDefaults.standard.bool(forKey: "APIServerAllowNetworkAccess") ? "0.0.0.0" : "localhost"):\(port)",
                port: port,
                isRunning: isRunning,
                requestsServed: requestCount,
                averageProcessingTimeMs: totalProcessingTime > 0 ? (totalProcessingTime / Double(requestCount)) * 1000 : 0
            ),
            transcription: TranscriptionInfo(
                currentModel: currentModel?.displayName,
                modelLoaded: modelLoaded,
                availableModels: availableModels,
                enhancementEnabled: await MainActor.run { whisperState.enhancementService?.isEnhancementEnabled ?? false },
                wordReplacementEnabled: UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled"),
                isQueuePaused: isPausedEffective,
                pauseReasons: pauseReasons.isEmpty ? nil : pauseReasons.map { $0.displayName },
                batteryOverrideProcessOnBattery: batteryOverrideProcessOnBattery
            ),
            capabilities: [
                "speech-to-text",
                "multi-model-support",
                "ai-enhancement",
                "word-replacement",
                "local-transcription",
                "cloud-transcription"
            ]
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(health)) ?? Data()
    }
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024 / 1024 : 0 // Convert to MB
    }
    
    // MARK: - API Queue Management

    /// Maximum number of requests that can be queued
    private let maxQueueSize = 10

    /// Enqueue a new transcription request
    func enqueueTranscription(requestId: String, filename: String?, fileSize: Int) -> APITranscriptionRequest? {
        // Check if queue is full
        guard transcriptionQueue.count < maxQueueSize else {
            logger.warning("Queue is full (\(self.maxQueueSize) requests), rejecting new request")
            return nil
        }

        // Check for duplicate request
        let existingRequest = transcriptionQueue.first { $0.requestId == requestId } ??
                             activeTranscriptions.first { $0.requestId == requestId }
        if existingRequest != nil {
            logger.warning("Duplicate request detected: \(requestId)")
            return nil
        }

        // Create new request
        let request = APITranscriptionRequest(requestId: requestId, filename: filename, fileSize: fileSize)

        // Add to queue
        transcriptionQueue.append(request)
        activeTranscriptions.append(request)

        // Update queue positions and wait times
        updateQueueInfo()

        logger.info("🟢 Enqueued transcription: \(filename ?? "unknown") (Queue: \(self.transcriptionQueue.count))")

        // Try to process next if no current processing and not paused
        if !isPausedEffective {
            processNextInQueue()
        } else {
            logger.info("⏸️ Queue is paused (\(self.pauseReasonsSummary)) - request queued but not started")
            updateQueueInfo() // Update to show paused state
        }

        return request
    }

    /// Process the next request in the queue
    private func processNextInQueue() {
        // Prevent reentrancy
        guard !isProcessingNext else {
            logger.debug("🔒 Preventing reentrancy in processNextInQueue")
            return
        }
        isProcessingNext = true
        defer { isProcessingNext = false }
        
        // Check if paused first
        if isPausedEffective {
            logger.debug("⏸️ Queue processing paused: \(self.pauseReasonsSummary)")
            updateQueueInfo() // Update queue info to show paused reason
            return
        }
        
        // Check if already processing something
        guard currentProcessingRequest == nil else {
            logger.debug("Already processing a request, queue will continue when complete")
            return
        }

        // Get next request from queue
        guard let nextRequest = transcriptionQueue.first else {
            logger.debug("No requests in queue")
            return
        }

        // Remove from queue and mark as processing
        transcriptionQueue.removeFirst()
        currentProcessingRequest = nextRequest
        nextRequest.updateStatus(.processing, info: "Starting transcription...")

        // Update remaining queue positions
        updateQueueInfo()

        logger.info("🔄 Started processing: \(nextRequest.displayFilename)")
    }

    /// Update queue positions and estimated wait times
    private func updateQueueInfo() {
        for (index, request) in transcriptionQueue.enumerated() {
            let position = index + 1
            
            if isPausedEffective {
                // Show paused state with reason
                let pauseInfo = pauseReasonsSummary.isEmpty ? "Paused" : "Paused: \(pauseReasonsSummary)"
                request.updateQueueInfo(position: position, estimatedWait: 0)
                if request.status == .queued {
                    request.updateStatus(.queued, info: "\(pauseInfo). Position \(position) in queue")
                }
            } else {
                // Normal operation - show estimated wait times
                let estimatedWait = TimeInterval(position * 60) // Rough estimate: 1 minute per request
                request.updateQueueInfo(position: position, estimatedWait: estimatedWait)
            }
        }
    }

    /// Complete the current processing request
    func completeCurrentRequest(result: Data?, transcriptionText: String?, error: String?) {
        guard let request = currentProcessingRequest else {
            logger.warning("No current request to complete")
            return
        }

        if let error = error {
            request.setError(error)
        } else if let result = result {
            request.setCompleted(result: result, transcriptionText: transcriptionText)
        }

        // Clear current processing
        currentProcessingRequest = nil

        // Clean up completed requests after some time (keep last 5)
        cleanupCompletedRequests()

        logger.info("✅ Completed request: \(request.displayFilename) (Status: \(request.status.displayName))")

        // Process next in queue
        processNextInQueue()
    }

    /// Remove completed requests, keeping the most recent ones
    private func cleanupCompletedRequests() {
        let completedRequests = activeTranscriptions.filter { !$0.status.isActive }
        if completedRequests.count > 5 {
            // Remove oldest completed requests, keeping the 5 most recent
            let sortedCompleted = completedRequests.sorted { $0.completedAt ?? Date.distantPast < $1.completedAt ?? Date.distantPast }
            let toRemove = sortedCompleted.dropLast(5)

            for request in toRemove {
                removeRequest(request, reason: "cleanup_overflow")
            }
        }
    }
    
    /// Centralized request removal function
    private func removeRequest(_ request: APITranscriptionRequest, reason: String) {
        logger.info("🗑️ Removing request \(request.displayFilename) (reason: \(reason))")
        
        // Clear auto-dismiss state
        request.clearAutoDismiss()
        
        // Remove from active transcriptions
        if let index = activeTranscriptions.firstIndex(of: request) {
            activeTranscriptions.remove(at: index)
        }
        
        // Remove from queue if present
        if let queueIndex = transcriptionQueue.firstIndex(of: request) {
            transcriptionQueue.remove(at: queueIndex)
        }
        
        // Clear as current processing if this is the active request
        if currentProcessingRequest?.id == request.id {
            currentProcessingRequest = nil
        }
    }
    
    /// Handle auto-dismiss notification
    @objc private func handleAutoDismissNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestIdString = userInfo["requestId"] as? String,
              let requestId = UUID(uuidString: requestIdString) else {
            logger.warning("Invalid auto-dismiss notification received")
            return
        }
        
        // Find the request to remove
        if let request = activeTranscriptions.first(where: { $0.id == requestId }) {
            removeRequest(request, reason: "auto_dismiss")
            logger.info("🔥 Auto-dismissed request: \(request.displayFilename)")
        }
    }

    /// Cancel a queued request
    func cancelQueuedRequest(_ request: APITranscriptionRequest) {
        guard request.status == .queued else {
            logger.warning("Cannot cancel request that is not queued: \(request.status.rawValue)")
            return
        }

        // Update status first
        request.updateStatus(.cancelled, info: "Cancelled by user")
        
        // Remove using centralized function
        removeRequest(request, reason: "user_cancel")

        // Update remaining queue positions
        updateQueueInfo()

        logger.info("❌ Cancelled queued request: \(request.displayFilename)")
    }

    /// Force stop all processing and clear queue
    func forceStopAPIProcessing() {
        // Cancel current processing request
        if let current = currentProcessingRequest {
            current.updateStatus(.cancelled, info: "Force stopped by user")
        }
        currentProcessingRequest = nil

        // Cancel all queued requests
        for request in transcriptionQueue {
            request.updateStatus(.cancelled, info: "Force stopped by user")
        }
        transcriptionQueue.removeAll()

        // Attempt to abort any in-flight Whisper computation
        Task { [weak self] in
            if let whisper = await self?.whisperState.whisperContext {
                await whisper.requestAbortNow()
            }
        }

        // Clear legacy active requests tracking
        self.activeRequests.removeAll()

        logger.warning("🛑 Force stopped all API transcription processing")
    }

    /// Legacy method for backward compatibility
    func setAPIProcessingState(isProcessing: Bool, info: String? = nil) {
        // This method is kept for backward compatibility but the state is now managed by the queue system
        if let request = currentProcessingRequest, let info = info {
            request.updateProgress(request.progress, info: info)
        }
    }
    
    /// Legacy method - now checks the new queue system
    func isRequestActive(_ requestId: String) -> Bool {
        // Clean up expired requests first
        cleanupExpiredRequests()

        // Check new queue system first
        let inNewSystem = activeTranscriptions.contains { $0.requestId == requestId }
        if inNewSystem {
            return true
        }
        // Fall back to legacy system for backward compatibility
        return activeRequests.keys.contains(requestId)
    }

    /// Remove expired requests from legacy tracking
    private func cleanupExpiredRequests() {
        let now = Date()
        let expiredKeys = activeRequests.filter { now.timeIntervalSince($0.value) > requestExpirationTime }.map { $0.key }

        for key in expiredKeys {
            activeRequests.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            logger.info("🗑️ Cleaned up \(expiredKeys.count) expired legacy requests")
        }
    }

    /// Legacy method - maintained for backward compatibility
    func addActiveRequest(_ requestId: String) {
        activeRequests[requestId] = Date()
        logger.info("📝 Added legacy active request: \(requestId) (total legacy: \(self.activeRequests.count))")
    }

    /// Legacy method - maintained for backward compatibility
    func removeActiveRequest(_ requestId: String) {
        activeRequests.removeValue(forKey: requestId)
        logger.info("✅ Removed legacy active request: \(requestId) (total legacy: \(self.activeRequests.count))")
    }

    /// Clear all legacy active requests (used on startup to prevent stale state)
    func clearLegacyActiveRequests() {
        let count = activeRequests.count
        activeRequests.removeAll()
        if count > 0 {
            logger.info("🧹 Cleared \(count) stale legacy active requests from API server")
        }
    }
    
    func updateAPITranscriptionStats(audioDuration: TimeInterval) {
        self.totalAudioDuration += audioDuration
    }
    
    private func loadAPIStatisticsFromDatabase(modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { $0.source == "api" }
            )
            let apiTranscriptions = try modelContext.fetch(descriptor)
            
            self.apiTranscriptionCount = apiTranscriptions.count
            self.totalAudioDuration = apiTranscriptions.reduce(0) { $0 + $1.duration }
            self.totalAPIProcessingTime = apiTranscriptions.reduce(0) { $0 + ($1.transcriptionDuration ?? 0) }
            
            print("Loaded API stats: \(apiTranscriptionCount) transcriptions, \(totalAudioDuration)s audio, \(totalAPIProcessingTime)s processing")
        } catch {
            print("Failed to load API statistics: \(error)")
        }
    }
    
    /// Handle voice recording will start notification
    @objc private func handleVoiceRecordingWillStart(_ notification: Notification) {
        logger.info("🎤 Voice recording starting - pausing API queue")
        setVoicePriorityPaused(true)
    }
    
    /// Handle voice recording did finish notification
    @objc private func handleVoiceRecordingDidFinish(_ notification: Notification) {
        logger.info("🎤 Voice recording finished - resuming API queue if conditions allow")
        setVoicePriorityPaused(false)
    }
}
