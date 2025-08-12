import Foundation
import Network
import os

/// Enhanced connection handler for large file uploads
@MainActor
class LargeFileTranscriptionHandler {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "LargeFileHandler")
    
    struct Configuration {
        // Maximum file size: 500MB (for 6-hour podcasts)
        static let maxFileSize = 500 * 1024 * 1024
        
        // Initial buffer: 64MB for large files
        static let initialBufferSize = 64 * 1024 * 1024
        
        // Chunk size for reading: 8MB
        static let chunkSize = 8 * 1024 * 1024
        
        // Connection timeout: 60 minutes (for 6-hour podcast episodes)
        static let connectionTimeout: TimeInterval = 3600
        
        // Keep-alive interval: 30 seconds
        static let keepAliveInterval: TimeInterval = 30
    }
    
    private var keepAliveTimer: Timer?
    private var lastActivityTime = Date()
    
    // Connection state for chunked reading
    private class ConnectionState {
        var accumulatedData = Data()
        var headersParsed = false
        var expectedContentLength = 0
        var boundary: String?
    }
    
    /// Handle connection with support for large files
    func handleLargeFileConnection(_ connection: NWConnection, queue: DispatchQueue, handler: TranscriptionAPIHandler) {
        // Don't start the connection - it's already started by the server
        
        // Set connection parameters for large transfers
        if let tcpConnection = connection as? NWConnection {
            tcpConnection.parameters.multipathServiceType = .handover
            tcpConnection.parameters.expiredDNSBehavior = .allow
        }
        
        // Start keep-alive mechanism
        startKeepAlive(for: connection)
        
        // Read request with chunked approach for large files
        let state = ConnectionState()
        
        readChunked(
            connection: connection,
            state: state,
            handler: handler,
            queue: queue
        )
    }
    
    /// Read data in chunks to handle large uploads
    private func readChunked(
        connection: NWConnection,
        state: ConnectionState,
        handler: TranscriptionAPIHandler,
        queue: DispatchQueue
    ) {
        // Update activity time
        lastActivityTime = Date()
        
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Configuration.chunkSize
        ) { [weak self, weak state] data, _, isComplete, error in
            guard let self = self, let state = state else {
                connection.cancel()
                return
            }
            
            if let error = error {
                self.logger.error("Connection error: \(error.localizedDescription)")
                self.stopKeepAlive()
                connection.cancel()
                return
            }
            
            if let data = data {
                state.accumulatedData.append(data)
                
                // Parse headers if not done yet
                if !state.headersParsed {
                    if let (headers, bodyStart) = self.parseHeaders(from: state.accumulatedData) {
                        state.headersParsed = true
                        
                        // Extract content length
                        state.expectedContentLength = self.extractContentLength(from: headers)
                        
                        // Extract boundary for multipart
                        state.boundary = self.extractBoundary(from: headers)
                        
                        // Check if this is a transcribe request
                        if headers.contains("POST /api/transcribe") {
                            self.logger.info("Receiving large file upload, Content-Length: \(state.expectedContentLength)")
                            
                            // Send 100 Continue if expected
                            if headers.contains("Expect: 100-continue") {
                                self.send100Continue(to: connection)
                            }
                        }
                    }
                }
                
                // Check if we have all the data
                if state.headersParsed && state.accumulatedData.count >= state.expectedContentLength {
                    self.logger.info("Received complete file: \(state.accumulatedData.count) bytes")
                    
                    // Process the complete request
                    Task {
                        await self.processLargeFileRequest(
                            data: state.accumulatedData,
                            boundary: state.boundary,
                            connection: connection,
                            handler: handler
                        )
                    }
                    return
                }
            }
            
            // Continue reading if not complete
            if !isComplete {
                self.readChunked(
                    connection: connection,
                    state: state,
                    handler: handler,
                    queue: queue
                )
            } else {
                // Connection closed before receiving all data
                self.logger.error("Connection closed prematurely. Received \(state.accumulatedData.count) of \(state.expectedContentLength) bytes")
                self.stopKeepAlive()
                connection.cancel()
            }
        }
    }
    
    /// Process large file request with progress updates
    private func processLargeFileRequest(
        data: Data,
        boundary: String?,
        connection: NWConnection,
        handler: TranscriptionAPIHandler
    ) async {
        // Send processing status
        sendProcessingStatus(to: connection, message: "Processing large audio file...")
        
        // Parse the request
        guard let separatorRange = data.range(of: "\r\n\r\n".data(using: .utf8)!) else {
            sendErrorResponse(to: connection, statusCode: 400, message: "Invalid request")
            stopKeepAlive()
            return
        }
        
        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            sendErrorResponse(to: connection, statusCode: 400, message: "Invalid headers")
            stopKeepAlive()
            return
        }
        
        // Extract body
        let bodyStart = separatorRange.upperBound
        let bodyData = data.subdata(in: bodyStart..<data.count)
        
        // Route the request
        if headers.contains("POST /api/transcribe") {
            await handleLargeTranscribeRequest(
                headers: headers,
                bodyData: bodyData,
                boundary: boundary,
                connection: connection,
                handler: handler
            )
        } else if headers.contains("GET /health") {
            sendHealthResponse(to: connection)
            stopKeepAlive()
        } else {
            sendErrorResponse(to: connection, statusCode: 404, message: "Not found")
            stopKeepAlive()
        }
    }
    
    /// Handle large transcription request with timeout management
    private func handleLargeTranscribeRequest(
        headers: String,
        bodyData: Data,
        boundary: String?,
        connection: NWConnection,
        handler: TranscriptionAPIHandler
    ) async {
        // Extract audio data
        guard let boundary = boundary,
              let audioData = extractAudioDataFromRaw(bodyData: bodyData, boundary: boundary) else {
            sendErrorResponse(to: connection, statusCode: 400, message: "No audio file found")
            stopKeepAlive()
            return
        }
        
        logger.info("Processing audio file: \(audioData.count / 1024 / 1024)MB")
        
        // Start transcription with timeout handling
        let startTime = Date()
        
        do {
            // Create a task with timeout
            let transcriptionTask = Task {
                try await handler.transcribe(audioData: audioData)
            }
            
            // Monitor progress
            var progressTimer: Timer?
            var lastProgressUpdate = Date()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                let elapsed = Date().timeIntervalSince(startTime)
                self.logger.info("Transcription in progress: \(Int(elapsed))s elapsed")
                
                // Update activity time to prevent keep-alive timeout
                self.lastActivityTime = Date()
                
                // Log progress for debugging
                let elapsedMinutes = Int(elapsed / 60)
                let elapsedSeconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
                self.logger.notice("Processing large file: \(elapsedMinutes)m \(elapsedSeconds)s elapsed")
            }
            
            // Wait for transcription with timeout
            let result = try await withTimeout(seconds: Configuration.connectionTimeout) {
                try await transcriptionTask.value
            }
            
            progressTimer?.invalidate()
            
            let processingTime = Date().timeIntervalSince(startTime)
            logger.info("Transcription completed in \(processingTime)s")
            
            // Send response
            sendJSONResponse(to: connection, data: result)
            
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            
            if error.localizedDescription.contains("timeout") {
                sendErrorResponse(to: connection, statusCode: 504, message: "Transcription timeout - file too large or complex")
            } else {
                sendErrorResponse(to: connection, statusCode: 500, message: error.localizedDescription)
            }
        }
        
        stopKeepAlive()
    }
    
    // MARK: - Keep-Alive Mechanism
    
    private func startKeepAlive(for connection: NWConnection) {
        stopKeepAlive() // Clear any existing timer
        
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: Configuration.keepAliveInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Check if connection is idle too long
            let idleTime = Date().timeIntervalSince(self.lastActivityTime)
            if idleTime > Configuration.connectionTimeout {
                self.logger.warning("Connection idle timeout")
                self.stopKeepAlive()
                connection.cancel()
                return
            }
            
            // Send keep-alive comment (ignored by HTTP clients)
            let keepAlive = "<!-- keep-alive -->\r\n".data(using: .utf8)!
            connection.send(content: keepAlive, completion: .contentProcessed { _ in
                // Keep connection alive
            })
        }
    }
    
    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    // MARK: - Helper Methods
    
    private func parseHeaders(from data: Data) -> (String, Int)? {
        guard let separator = "\r\n\r\n".data(using: .utf8),
              let separatorRange = data.range(of: separator) else {
            return nil
        }
        
        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        
        return (headers, separatorRange.upperBound)
    }
    
    private func extractContentLength(from headers: String) -> Int {
        let lines = headers.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
            }
        }
        return 0
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
        let boundaryData = "--\(boundary)".data(using: .utf8)!
        let headerSeparator = "\r\n\r\n".data(using: .utf8)!
        
        var currentIndex = 0
        while currentIndex < bodyData.count {
            guard let boundaryRange = bodyData.range(of: boundaryData, in: currentIndex..<bodyData.count) else {
                break
            }
            
            let partStart = boundaryRange.upperBound
            guard let headerEndRange = bodyData.range(of: headerSeparator, in: partStart..<bodyData.count) else {
                currentIndex = partStart
                continue
            }
            
            let headerData = bodyData.subdata(in: partStart..<headerEndRange.lowerBound)
            guard let headers = String(data: headerData, encoding: .utf8) else {
                currentIndex = headerEndRange.upperBound
                continue
            }
            
            if headers.contains("Content-Disposition: form-data") && headers.contains("name=\"file\"") {
                let dataStart = headerEndRange.upperBound
                
                var dataEnd = bodyData.count
                if let nextBoundaryRange = bodyData.range(of: boundaryData, in: dataStart..<bodyData.count) {
                    dataEnd = nextBoundaryRange.lowerBound
                    if dataEnd >= 2 {
                        dataEnd -= 2
                    }
                }
                
                return bodyData.subdata(in: dataStart..<dataEnd)
            }
            
            currentIndex = headerEndRange.upperBound
        }
        
        return nil
    }
    
    // MARK: - Response Methods
    
    private func send100Continue(to connection: NWConnection) {
        let response = "HTTP/1.1 100 Continue\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }
    
    private func sendProcessingStatus(to connection: NWConnection, message: String) {
        // Send processing header to keep connection alive
        let response = """
        HTTP/1.1 102 Processing\r
        Status: \(message)\r
        \r
        
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }
    
    private func sendJSONResponse(to connection: NWConnection, data: Data) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        
        """
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(data)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendErrorResponse(to connection: NWConnection, statusCode: Int, message: String) {
        let json = """
        {"success":false,"error":{"code":"\(statusCode)","message":"\(message)"}}
        """
        
        let statusText = statusCode == 404 ? "Not Found" :
                        statusCode == 400 ? "Bad Request" :
                        statusCode == 504 ? "Gateway Timeout" :
                        statusCode == 500 ? "Internal Server Error" : "Error"
        
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(json.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(json)
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendHealthResponse(to connection: NWConnection) {
        // Get proper health status from the server
        Task {
            let healthData = await getHealthStatus()
            let response = """
            HTTP/1.1 200 OK\r\n\
            Content-Type: application/json\r\n\
            Content-Length: \(healthData.count)\r\n\
            Access-Control-Allow-Origin: *\r\n\
            \r\n
            """
            
            var responseData = response.data(using: .utf8) ?? Data()
            responseData.append(healthData)
            
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    private func getHealthStatus() async -> Data {
        // This is a simplified version - in production you'd get the real status
        let health = [
            "status": "healthy",
            "service": "VoiceInk API",
            "maxFileSize": Configuration.maxFileSize,
            "timeout": Configuration.connectionTimeout,
            "capabilities": [
                "large-file-support",
                "chunked-upload",
                "progress-updates"
            ]
        ] as [String: Any]
        
        return (try? JSONSerialization.data(withJSONObject: health)) ?? Data()
    }
}

// MARK: - Timeout Helper

private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}