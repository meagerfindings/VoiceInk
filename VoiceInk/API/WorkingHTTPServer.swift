import Foundation
import Darwin
import os

// MARK: - Timeout Helper for WorkingHTTPServer

struct WorkingHTTPTimeoutError: Error {
    let duration: TimeInterval
}

func withTimeout<T>(seconds: TimeInterval, transcriptionProcessor: TranscriptionProcessor? = nil, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        // Add the actual operation
        group.addTask {
            try await operation()
        }

        // Add the timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            
            // On timeout, immediately abort any running whisper computation
            if let processor = transcriptionProcessor {
                await processor.requestAbortNow()
            }
            
            throw WorkingHTTPTimeoutError(duration: seconds)
        }

        // Return the first result and cancel the rest
        guard let result = try await group.next() else {
            throw WorkingHTTPTimeoutError(duration: seconds)
        }
        group.cancelAll()
        return result
    }
}

/// Working HTTP Server implementation using BSD sockets
/// Replaces broken NWConnection that hangs on receive() callbacks
class WorkingHTTPServer {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "WorkingHTTPServer")
    
    private let port: Int
    private let allowNetworkAccess: Bool
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "working.http.server", qos: .userInitiated)
    
    // Request deduplication
    private var activeRequests: Set<String> = Set()
    private let requestsQueue = DispatchQueue(label: "working.http.server.requests", qos: .userInitiated)
    
    // Dependencies
    private let transcriptionProcessor: TranscriptionProcessor
    weak var delegate: WorkingHTTPServerDelegate?
    weak var apiServer: TranscriptionAPIServer?

    init(port: Int, allowNetworkAccess: Bool, transcriptionProcessor: TranscriptionProcessor) {
        self.port = port
        self.allowNetworkAccess = allowNetworkAccess
        self.transcriptionProcessor = transcriptionProcessor
    }
    
    // MARK: - Request Deduplication
    
    private func generateRequestId(from data: Data, filename: String?) -> String {
        let hasher = data.hashValue
        return "\(filename ?? "unknown")_\(hasher)_\(data.count)"
    }
    
    private func addActiveRequest(_ requestId: String) -> Bool {
        return requestsQueue.sync {
            if activeRequests.contains(requestId) {
                return false
            }
            activeRequests.insert(requestId)
            return true
        }
    }
    
    private func removeActiveRequest(_ requestId: String) {
        requestsQueue.sync {
            _ = activeRequests.remove(requestId)
        }
    }

    private func clearActiveRequests() {
        requestsQueue.sync {
            let count = activeRequests.count
            activeRequests.removeAll()
            if count > 0 {
                logger.info("🧹 Cleared \(count) stale active requests from previous session")
            }
        }
    }
    
    func start() throws {
        guard !isRunning else { return }
        
        logger.info("🚀 Starting Working HTTP Server on port \(self.port)...")
        
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket != -1 else {
            throw HTTPServerError.socketCreationFailed
        }
        
        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to address
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = UInt16(port).bigEndian
        serverAddr.sin_addr.s_addr = allowNetworkAccess ? INADDR_ANY : inet_addr("127.0.0.1")
        
        let bindResult = withUnsafePointer(to: &serverAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult != -1 else {
            close(serverSocket)
            throw HTTPServerError.bindFailed
        }
        
        // Listen for connections
        guard listen(serverSocket, 5) != -1 else {
            close(serverSocket)
            throw HTTPServerError.listenFailed
        }
        
        isRunning = true

        // Clear any stale requests from previous sessions
        clearActiveRequests()

        logger.info("✅ Working HTTP Server listening on port \(self.port)")

        // Start accepting connections on background queue
        serverQueue.async { [weak self] in
            self?.acceptConnections()
        }
        
        // Notify delegate
        Task { @MainActor in
            delegate?.httpServer(self, didChangeState: true)
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        
        if serverSocket != -1 {
            close(serverSocket)
            serverSocket = -1
        }
        
        logger.info("🛑 Working HTTP Server stopped")
        
        Task { @MainActor in
            delegate?.httpServer(self, didChangeState: false)
        }
    }
    
    private func acceptConnections() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientAddrLen)
                }
            }

            guard clientSocket != -1 else {
                let errorCode = errno
                if isRunning {
                    if errorCode == EINTR {
                        // Interrupted by signal, just continue
                        continue
                    } else if errorCode == EAGAIN || errorCode == EWOULDBLOCK {
                        // Non-blocking socket would block, add delay
                        logger.debug("No pending connections, sleeping briefly")
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    } else {
                        logger.error("Failed to accept client connection: errno=\(errorCode)")
                        // Add delay on any other error to prevent busy loop
                        Thread.sleep(forTimeInterval: 0.5)
                        continue
                    }
                }
                break
            }

            logger.debug("🔗 New client connection accepted: socket \(clientSocket)")

            // Handle connection asynchronously
            Task { [weak self] in
                await self?.handleConnection(clientSocket: clientSocket)
            }
        }
    }
    
    private func handleConnection(clientSocket: Int32) async {
        defer {
            logger.debug("🔚 Closing socket \(clientSocket)")
            close(clientSocket)
        }
        
        let connectionId = String(clientSocket)
        let startTime = Date()
        
        logger.debug("📡 CONN-\(connectionId): Processing connection...")
        
        // Read HTTP request
        guard let request = readHTTPRequest(from: clientSocket, connectionId: connectionId) else {
            logger.error("🔴 CONN-\(connectionId): Failed to read HTTP request")
            return
        }
        
        logger.debug("📥 CONN-\(connectionId): Request parsed - \(request.method) \(request.path) (body: \(request.body.count) bytes)")
        
        // Route and process request
        let response: HTTPResponse
        do {
            response = try await routeRequest(request, connectionId: connectionId)
        } catch {
            logger.error("🔴 CONN-\(connectionId): Request processing failed: \(error)")
            response = HTTPResponse.error(500, "Internal Server Error")
        }
        
        logger.debug("📤 CONN-\(connectionId): Sending response (status: \(response.statusCode), size: \(response.data.count) bytes)")
        
        // Send response
        sendHTTPResponse(response, to: clientSocket, connectionId: connectionId)
        
        let processingTime = Date().timeIntervalSince(startTime)
        logger.info("✅ CONN-\(connectionId): Completed in \(String(format: "%.2f", processingTime))s")
        
        // Report stats to delegate
        let stats = RequestStats(
            method: request.method,
            path: request.path,
            processingTime: processingTime,
            success: response.statusCode < 400
        )
        
        Task { @MainActor in
            delegate?.httpServer(self, didProcessRequest: stats)
        }
    }
    
    private func readHTTPRequest(from socket: Int32, connectionId: String) -> HTTPRequest? {
        var buffer = Data()
        var totalRead = 0
        let maxHeaderSize = 8192 // 8KB max for headers
        
        // Read until we have complete headers
        while totalRead < maxHeaderSize {
            var chunk = Data(count: 1024)
            let bytesRead = chunk.withUnsafeMutableBytes { bytes in
                recv(socket, bytes.baseAddress, bytes.count, 0)
            }
            
            guard bytesRead > 0 else {
                logger.error("🔴 CONN-\(connectionId): Failed to read from socket")
                return nil
            }
            
            chunk.count = bytesRead
            buffer.append(chunk)
            totalRead += bytesRead
            
            // Check for end of headers by searching for \r\n\r\n in the raw bytes
            let headerEndMarker = Data([13, 10, 13, 10]) // \r\n\r\n
            if let headerEndRange = buffer.range(of: headerEndMarker) {
                let headerEnd = headerEndRange.upperBound
                
                // Extract just the header portion and convert to string
                let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    logger.error("🔴 CONN-\(connectionId): Headers are not valid UTF-8")
                    return nil
                }
                
                // Parse request line and headers
                guard let request = parseHTTPHeaders(headerString, connectionId: connectionId) else {
                    return nil
                }
                
                // Read body if present
                if let contentLength = request.contentLength {
                    // Body starts after the header end marker
                    var bodyData = buffer.subdata(in: headerEnd..<buffer.endIndex)
                    
                    logger.debug("📦 CONN-\(connectionId): Need to read \(contentLength) bytes total, have \(bodyData.count) from initial buffer")
                    
                    // Read remaining body data if needed
                    while bodyData.count < contentLength {
                        let remaining = contentLength - bodyData.count
                        let chunkSize = min(65536, remaining)
                        logger.debug("📥 CONN-\(connectionId): Reading chunk of \(chunkSize) bytes (need \(remaining) more)")
                        
                        var chunk = Data(count: chunkSize)
                        let bytesRead = chunk.withUnsafeMutableBytes { bytes in
                            recv(socket, bytes.baseAddress, bytes.count, 0)
                        }
                        
                        if bytesRead == -1 {
                            logger.error("🔴 CONN-\(connectionId): recv() error: errno=\(errno)")
                            return nil
                        }
                        
                        guard bytesRead > 0 else {
                            logger.error("🔴 CONN-\(connectionId): Connection closed while reading body (needed \(remaining) more bytes)")
                            return nil
                        }
                        
                        chunk.count = bytesRead
                        bodyData.append(chunk)
                        logger.debug("📦 CONN-\(connectionId): Read \(bytesRead) bytes, total: \(bodyData.count)/\(contentLength)")
                    }
                    
                    return HTTPRequest(
                        method: request.method,
                        path: request.path,
                        headers: request.headers,
                        body: bodyData,
                        contentLength: contentLength
                    )
                } else {
                    return request
                }
            }
        }
        
        logger.error("🔴 CONN-\(connectionId): Headers too large or malformed")
        return nil
    }
    
    private func parseHTTPHeaders(_ headerString: String, connectionId: String) -> HTTPRequest? {
        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        
        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 3 else { return nil }
        
        let method = requestLine[0]
        let path = requestLine[1]
        
        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonRange = line.range(of: ":") {
                let key = String(line.prefix(upTo: colonRange.lowerBound)).trimmingCharacters(in: .whitespaces)
                let value = String(line.suffix(from: colonRange.upperBound)).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }
        
        let contentLength = headers["content-length"].flatMap { Int($0) }
        
        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: Data(),
            contentLength: contentLength
        )
    }
    
    private func routeRequest(_ request: HTTPRequest, connectionId: String) async throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return handleHealthRequest(connectionId: connectionId)
            
        case ("GET", "/test"):
            return handleTestRequest(connectionId: connectionId)
            
        case ("POST", "/echo"):
            return handleEchoRequest(request, connectionId: connectionId)
            
        case ("POST", "/api/transcribe"):
            return try await handleTranscriptionRequest(request, connectionId: connectionId)
            
        case ("OPTIONS", _):
            return HTTPResponse.options()
            
        default:
            return HTTPResponse.error(404, "Not Found")
        }
    }
    
    private func handleHealthRequest(connectionId: String) -> HTTPResponse {
        logger.debug("🏥 CONN-\(connectionId): Processing health check")
        
        let healthData: [String: Any] = [
            "status": "healthy",
            "service": "VoiceInk API",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "version": "2.0-working-http"
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: healthData) else {
            return HTTPResponse.error(500, "Failed to serialize health data")
        }
        
        return HTTPResponse.success(data: jsonData, contentType: "application/json")
    }
    
    private func handleTestRequest(connectionId: String) -> HTTPResponse {
        logger.debug("🧪 CONN-\(connectionId): Processing test request")
        
        let testData: [String: Any] = [
            "test": "success",
            "message": "BSD socket server is working!",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: testData) else {
            return HTTPResponse.error(500, "Failed to serialize test data")
        }
        
        return HTTPResponse.success(data: jsonData, contentType: "application/json")
    }
    
    private func handleEchoRequest(_ request: HTTPRequest, connectionId: String) -> HTTPResponse {
        logger.debug("📢 CONN-\(connectionId): Processing echo request")
        
        let echoData: [String: Any] = [
            "echo": "success",
            "bodySize": request.body.count,
            "method": request.method,
            "path": request.path,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: echoData) else {
            return HTTPResponse.error(500, "Failed to serialize echo data")
        }
        
        return HTTPResponse.success(data: jsonData, contentType: "application/json")
    }
    
    private func handleTranscriptionRequest(_ request: HTTPRequest, connectionId: String) async throws -> HTTPResponse {
        logger.info("🎤 CONN-\(connectionId): Processing transcription request, body size: \(request.body.count)")

        guard let boundary = extractBoundary(from: request.headers["content-type"]) else {
            logger.error("🔴 CONN-\(connectionId): No boundary in content-type: \(request.headers["content-type"] ?? "nil")")
            return HTTPResponse.error(400, "Missing boundary in multipart/form-data")
        }

        logger.debug("📋 CONN-\(connectionId): Extracting file with boundary: \(boundary)")

        guard let fileResult = extractFileFromMultipart(request.body, boundary: boundary, connectionId: connectionId) else {
            logger.error("🔴 CONN-\(connectionId): Failed to extract file from multipart data")
            return HTTPResponse.error(400, "No file found in request")
        }

        let fileData = fileResult.data
        let filename = fileResult.filename

        logger.info("🎉 CONN-\(connectionId): File extracted successfully, size: \(fileData.count) bytes, filename: \(filename ?? "none")")

        let requestId = generateRequestId(from: fileData, filename: filename)

        // Use new queue system if available
        if let apiServer = await MainActor.run(body: { self.apiServer }) {
            logger.debug("🟢 CONN-\(connectionId): Using new queue system")

            let queueRequest = await MainActor.run {
                apiServer.enqueueTranscription(requestId: requestId, filename: filename, fileSize: fileData.count)
            }

            guard let queueRequest = queueRequest else {
                if await MainActor.run(body: { apiServer.isRequestActive(requestId) }) {
                    logger.warning("⚠️ CONN-\(connectionId): Duplicate request detected")
                    return HTTPResponse.error(409, "Request already in progress")
                } else {
                    logger.error("🔴 CONN-\(connectionId): Queue is full")
                    return HTTPResponse.error(503, "Server is too busy. Queue is full. Please try again later.")
                }
            }

            // Store the audio data for processing when request reaches front of queue
            Task { @MainActor in
                // Process the transcription when it's this request's turn
                await processQueuedTranscription(queueRequest: queueRequest, audioData: fileData, filename: filename, connectionId: connectionId)
            }

            // Return immediate response with queue information
            let queueResponse = APIQueueResponse(
                success: true,
                requestId: requestId,
                message: "Request queued successfully",
                queuePosition: await MainActor.run { queueRequest.queuePosition },
                estimatedWaitTime: await MainActor.run { queueRequest.estimatedWaitTime }
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let responseData = try encoder.encode(queueResponse)

            let position = await MainActor.run { queueRequest.queuePosition }
            logger.info("📤 CONN-\(connectionId): Returning queue response - Position: \(position)")
            return HTTPResponse.success(data: responseData, contentType: "application/json")
        } else {
            // Fall back to old immediate processing system
            logger.debug("⚠️ CONN-\(connectionId): API Server not available, falling back to immediate processing")
            return await handleImmediateTranscription(requestId: requestId, fileData: fileData, filename: filename, connectionId: connectionId)
        }
    }

    /// Process a queued transcription when it reaches the front of the queue
    private func processQueuedTranscription(queueRequest: APITranscriptionRequest, audioData: Data, filename: String?, connectionId: String) async {
        // Wait for this request to become the current processing request
        while await MainActor.run(body: { apiServer?.currentProcessingRequest?.id != queueRequest.id }) {
            // Check if request was cancelled
            let status = await MainActor.run { queueRequest.status }
            if status == .cancelled {
                logger.info("❌ CONN-\(connectionId): Request was cancelled while waiting in queue")
                return
            }

            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        logger.info("🔄 CONN-\(connectionId): Processing queued transcription: \(filename ?? "unknown")")

        do {
            // Update progress
            await MainActor.run {
                queueRequest.updateProgress(0.1, info: "Starting transcription...")
            }

            // Process transcription
            let result = try await withTimeout(seconds: 900, transcriptionProcessor: transcriptionProcessor) { [self] in
                try await transcriptionProcessor.transcribe(audioData: audioData, filename: filename)
            }

            // Extract transcription text for display
            let transcriptionText: String?
            if let jsonObject = try? JSONSerialization.jsonObject(with: result, options: []) as? [String: Any],
               let text = jsonObject["text"] as? String {
                transcriptionText = text
            } else {
                transcriptionText = nil
            }

            // Complete the request
            await MainActor.run {
                apiServer?.completeCurrentRequest(result: result, transcriptionText: transcriptionText, error: nil)
            }

            logger.info("✅ CONN-\(connectionId): Queued transcription completed successfully")

        } catch {
            logger.error("🔴 CONN-\(connectionId): Queued transcription failed: \(error.localizedDescription)")

            let errorMessage: String
            if error is WorkingHTTPTimeoutError {
                errorMessage = "Transcription timeout: Request took longer than 15 minutes."
            } else {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
            }

            await MainActor.run {
                apiServer?.completeCurrentRequest(result: nil, transcriptionText: nil, error: errorMessage)
            }
        }
    }

    /// Fallback to immediate processing (legacy behavior)
    private func handleImmediateTranscription(requestId: String, fileData: Data, filename: String?, connectionId: String) async -> HTTPResponse {
        // Check for duplicate request using legacy system
        guard addActiveRequest(requestId) else {
            logger.warning("⚠️ CONN-\(connectionId): Duplicate request detected (legacy system)")
            return HTTPResponse.error(409, "Request already in progress")
        }

        // Ensure cleanup happens regardless of success/failure
        defer {
            removeActiveRequest(requestId)
            logger.debug("🧹 CONN-\(connectionId): Legacy request tracking cleaned up")
        }

        let transcriptionResult: Data
        do {
            transcriptionResult = try await withTimeout(seconds: 900, transcriptionProcessor: transcriptionProcessor) { [self] in
                try await transcriptionProcessor.transcribe(audioData: fileData, filename: filename)
            }
            logger.debug("✅ CONN-\(connectionId): Legacy transcription completed, result size: \(transcriptionResult.count) bytes")
        } catch {
            logger.error("🔴 CONN-\(connectionId): Legacy transcription failed: \(error)")

            if error is WorkingHTTPTimeoutError {
                return HTTPResponse.error(504, "Transcription timeout: Request took longer than 15 minutes. Try with smaller files or check server load.")
            } else {
                return HTTPResponse.error(500, "Transcription failed: \(error.localizedDescription)")
            }
        }

        return HTTPResponse.success(data: transcriptionResult, contentType: "application/json")
    }
    
    private func sendHTTPResponse(_ response: HTTPResponse, to socket: Int32, connectionId: String) {
        let responseString = "HTTP/1.1 \(response.statusCode) \(response.statusMessage)\r\n" +
                            "Content-Type: \(response.contentType)\r\n" +
                            "Content-Length: \(response.data.count)\r\n" +
                            "Access-Control-Allow-Origin: *\r\n" +
                            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                            "Access-Control-Allow-Headers: Content-Type\r\n" +
                            "\r\n"
        
        guard let headerData = responseString.data(using: .utf8) else {
            logger.error("🔴 CONN-\(connectionId): Failed to encode response headers")
            return
        }
        
        // Send headers
        logger.debug("📤 CONN-\(connectionId): Sending headers (\(headerData.count) bytes)...")
        let headerBytesSent = headerData.withUnsafeBytes { bytes in
            send(socket, bytes.baseAddress, bytes.count, 0)
        }
        
        if headerBytesSent == -1 {
            logger.error("🔴 CONN-\(connectionId): Failed to send headers - errno: \(errno)")
            return
        }
        
        guard headerBytesSent == headerData.count else {
            logger.error("🔴 CONN-\(connectionId): Partial header send: \(headerBytesSent)/\(headerData.count)")
            return
        }
        
        // Send body if present
        if response.data.count > 0 {
            logger.debug("📤 CONN-\(connectionId): Sending body (\(response.data.count) bytes)...")
            let bodyBytesSent = response.data.withUnsafeBytes { bytes in
                send(socket, bytes.baseAddress, bytes.count, 0)
            }
            
            if bodyBytesSent == -1 {
                logger.error("🔴 CONN-\(connectionId): Failed to send body - errno: \(errno)")
                return
            }
            
            guard bodyBytesSent == response.data.count else {
                logger.error("🔴 CONN-\(connectionId): Partial body send: \(bodyBytesSent)/\(response.data.count)")
                return
            }
        }
        
        logger.debug("📤 CONN-\(connectionId): Response sent - \(response.statusCode) (\(response.data.count) bytes)")
    }
    
    private func extractBoundary(from contentType: String?) -> String? {
        guard let contentType = contentType,
              let boundaryRange = contentType.range(of: "boundary=") else {
            return nil
        }
        
        return String(contentType.suffix(from: boundaryRange.upperBound))
    }
    
    private func extractFilename(from headerString: String) -> String? {
        // Look for filename= in the Content-Disposition header
        guard let filenameRange = headerString.range(of: "filename=") else {
            return nil
        }
        
        let afterFilename = headerString.suffix(from: filenameRange.upperBound)
        
        // Handle quoted filenames
        if afterFilename.hasPrefix("\"") {
            let quotedContent = afterFilename.dropFirst()
            if let endQuote = quotedContent.firstIndex(of: "\"") {
                return String(quotedContent.prefix(upTo: endQuote))
            }
        }
        
        // Handle unquoted filenames (up to semicolon or end of line)
        let filename = afterFilename.components(separatedBy: CharacterSet(charactersIn: ";\r\n")).first ?? ""
        return filename.trimmingCharacters(in: .whitespaces).isEmpty ? nil : filename.trimmingCharacters(in: .whitespaces)
    }
    
    private func extractFileFromMultipart(_ data: Data, boundary: String, connectionId: String) -> (data: Data, filename: String?)? {
        let boundaryData = ("--" + boundary).data(using: .utf8)!
        let doubleCRLF = "\r\n\r\n".data(using: .utf8)!
        let endBoundaryData = ("\r\n--" + boundary).data(using: .utf8)!
        
        // Split by boundary
        var currentIndex = data.startIndex
        
        while currentIndex < data.endIndex {
            // Find next boundary
            guard let boundaryRange = data.range(of: boundaryData, options: [], in: currentIndex..<data.endIndex) else {
                break
            }
            
            // Move past boundary and CRLF
            currentIndex = boundaryRange.upperBound
            if currentIndex + 2 <= data.endIndex && data[currentIndex] == 13 && data[currentIndex + 1] == 10 { // \r\n
                currentIndex += 2
            }
            
            // Find the header/body separator
            guard let headerEndRange = data.range(of: doubleCRLF, options: [], in: currentIndex..<data.endIndex) else {
                continue
            }
            
            // Extract headers
            let headerData = data.subdata(in: currentIndex..<headerEndRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                continue
            }
            
            // Check if this part contains a file
            if headerString.contains("filename=") && headerString.contains("Content-Type:") {
                // Extract filename from headers
                let filename = extractFilename(from: headerString)
                
                // Start of file data
                let fileStart = headerEndRange.upperBound
                
                // Find end of this part (next boundary or end of data)
                var fileEnd: Data.Index
                if let nextBoundaryRange = data.range(of: endBoundaryData, options: [], in: fileStart..<data.endIndex) {
                    fileEnd = nextBoundaryRange.lowerBound
                } else {
                    // No end boundary found, use end of data
                    fileEnd = data.endIndex
                }
                
                // Extract file data
                let fileData = data.subdata(in: fileStart..<fileEnd)
                logger.debug("📁 CONN-\(connectionId): File extracted from multipart, size: \(fileData.count), filename: \(filename ?? "none")")
                return (data: fileData, filename: filename)
            }
        }
        
        logger.error("🔴 CONN-\(connectionId): No file found in multipart data")
        return nil
    }
}

// MARK: - Supporting Types

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let contentLength: Int?
}

struct HTTPResponse {
    let statusCode: Int
    let statusMessage: String
    let contentType: String
    let data: Data
    
    static func success(data: Data, contentType: String = "application/json") -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            contentType: contentType,
            data: data
        )
    }
    
    static func error(_ code: Int, _ message: String) -> HTTPResponse {
        let errorData = "{\"error\":\"\(message)\"}".data(using: .utf8) ?? Data()
        return HTTPResponse(
            statusCode: code,
            statusMessage: message,
            contentType: "application/json",
            data: errorData
        )
    }
    
    static func options() -> HTTPResponse {
        return HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            contentType: "text/plain",
            data: Data()
        )
    }
}

enum HTTPServerError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
}

// MARK: - API Queue Response

/// Response sent to clients when a request is queued
struct APIQueueResponse: Codable {
    let success: Bool
    let requestId: String
    let message: String
    let queuePosition: Int
    let estimatedWaitTime: TimeInterval

    enum CodingKeys: String, CodingKey {
        case success
        case requestId = "request_id"
        case message
        case queuePosition = "queue_position"
        case estimatedWaitTime = "estimated_wait_time_seconds"
    }
}

protocol WorkingHTTPServerDelegate: AnyObject {
    func httpServer(_ server: WorkingHTTPServer, didChangeState isRunning: Bool)
    func httpServer(_ server: WorkingHTTPServer, didEncounterError error: String)
    func httpServer(_ server: WorkingHTTPServer, didProcessRequest stats: RequestStats)
}