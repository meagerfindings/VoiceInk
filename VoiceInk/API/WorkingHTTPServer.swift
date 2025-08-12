import Foundation
import Darwin
import os

/// Working HTTP Server implementation using BSD sockets
/// Replaces broken NWConnection that hangs on receive() callbacks
class WorkingHTTPServer {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "WorkingHTTPServer")
    
    private let port: Int
    private let allowNetworkAccess: Bool
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "working.http.server", qos: .userInitiated)
    
    // Dependencies
    private let transcriptionProcessor: TranscriptionProcessor
    weak var delegate: WorkingHTTPServerDelegate?
    
    init(port: Int, allowNetworkAccess: Bool, transcriptionProcessor: TranscriptionProcessor) {
        self.port = port
        self.allowNetworkAccess = allowNetworkAccess
        self.transcriptionProcessor = transcriptionProcessor
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
                if isRunning {
                    logger.error("Failed to accept client connection")
                }
                continue
            }
            
            logger.debug("🔗 New client connection accepted: socket \(clientSocket)")
            
            // Handle connection on separate queue
            let connectionQueue = DispatchQueue(label: "connection.\(clientSocket)", qos: .userInitiated)
            connectionQueue.async { [weak self] in
                self?.handleConnection(clientSocket: clientSocket)
            }
        }
    }
    
    private func handleConnection(clientSocket: Int32) {
        defer {
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
        
        logger.debug("📥 CONN-\(connectionId): Request parsed - \(request.method) \(request.path)")
        
        // Route and process request
        let response: HTTPResponse
        do {
            response = try routeRequest(request, connectionId: connectionId)
        } catch {
            logger.error("🔴 CONN-\(connectionId): Request processing failed: \(error)")
            response = HTTPResponse.error(500, "Internal Server Error")
        }
        
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
            
            // Check for end of headers
            if let headerData = String(data: buffer, encoding: .utf8),
               let headerEndRange = headerData.range(of: "\r\n\r\n") {
                let headerEnd = headerData.distance(from: headerData.startIndex, to: headerEndRange.upperBound)
                let headers = String(headerData.prefix(headerEnd - 4)) // Remove \r\n\r\n
                
                // Parse request line and headers
                guard let request = parseHTTPHeaders(headers, connectionId: connectionId) else {
                    return nil
                }
                
                // Read body if present
                if let contentLength = request.contentLength {
                    let bodyStart = headerEnd
                    var bodyData = Data(buffer.dropFirst(bodyStart))
                    
                    // Read remaining body data if needed
                    while bodyData.count < contentLength {
                        var chunk = Data(count: min(65536, contentLength - bodyData.count))
                        let bytesRead = chunk.withUnsafeMutableBytes { bytes in
                            recv(socket, bytes.baseAddress, bytes.count, 0)
                        }
                        
                        guard bytesRead > 0 else {
                            logger.error("🔴 CONN-\(connectionId): Failed to read body data")
                            return nil
                        }
                        
                        chunk.count = bytesRead
                        bodyData.append(chunk)
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
    
    private func routeRequest(_ request: HTTPRequest, connectionId: String) throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return handleHealthRequest(connectionId: connectionId)
            
        case ("POST", "/api/transcribe"):
            return try handleTranscriptionRequest(request, connectionId: connectionId)
            
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
    
    private func handleTranscriptionRequest(_ request: HTTPRequest, connectionId: String) throws -> HTTPResponse {
        logger.info("🎤 CONN-\(connectionId): Processing transcription request")
        
        guard let boundary = extractBoundary(from: request.headers["content-type"]) else {
            return HTTPResponse.error(400, "Missing boundary in multipart/form-data")
        }
        
        guard let fileData = extractFileFromMultipart(request.body, boundary: boundary, connectionId: connectionId) else {
            return HTTPResponse.error(400, "No file found in request")
        }
        
        logger.info("🎤 CONN-\(connectionId): File extracted, size: \(fileData.count) bytes")
        
        // Process transcription synchronously using async/await
        let semaphore = DispatchSemaphore(value: 0)
        var transcriptionResult: Data?
        var transcriptionError: Error?
        
        Task {
            do {
                transcriptionResult = try await transcriptionProcessor.transcribe(audioData: fileData)
            } catch {
                transcriptionError = error
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = transcriptionError {
            logger.error("🔴 CONN-\(connectionId): Transcription failed: \(error)")
            return HTTPResponse.error(500, "Transcription failed: \(error.localizedDescription)")
        }
        
        guard let result = transcriptionResult else {
            return HTTPResponse.error(500, "Transcription returned no data")
        }
        
        return HTTPResponse.success(data: result, contentType: "application/json")
    }
    
    private func sendHTTPResponse(_ response: HTTPResponse, to socket: Int32, connectionId: String) {
        let responseString = """
        HTTP/1.1 \(response.statusCode) \(response.statusMessage)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.data.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        \r
        
        """
        
        guard let headerData = responseString.data(using: .utf8) else {
            logger.error("🔴 CONN-\(connectionId): Failed to encode response headers")
            return
        }
        
        // Send headers
        let headerBytesSent = headerData.withUnsafeBytes { bytes in
            send(socket, bytes.baseAddress, bytes.count, 0)
        }
        
        guard headerBytesSent == headerData.count else {
            logger.error("🔴 CONN-\(connectionId): Failed to send response headers")
            return
        }
        
        // Send body
        let bodyBytesSent = response.data.withUnsafeBytes { bytes in
            send(socket, bytes.baseAddress, bytes.count, 0)
        }
        
        guard bodyBytesSent == response.data.count else {
            logger.error("🔴 CONN-\(connectionId): Failed to send response body")
            return
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
    
    private func extractFileFromMultipart(_ data: Data, boundary: String, connectionId: String) -> Data? {
        guard let bodyString = String(data: data, encoding: .utf8) else {
            logger.error("🔴 CONN-\(connectionId): Failed to decode multipart body")
            return nil
        }
        
        let boundaryMarker = "--" + boundary
        let parts = bodyString.components(separatedBy: boundaryMarker)
        
        for part in parts {
            if part.contains("filename=") && part.contains("Content-Type:") {
                // Find the start of file data (after headers)
                if let dataStartRange = part.range(of: "\r\n\r\n") {
                    let dataStart = part.distance(from: part.startIndex, to: dataStartRange.upperBound)
                    let fileContent = String(part.suffix(from: part.index(part.startIndex, offsetBy: dataStart)))
                    
                    // Remove trailing boundary markers
                    let cleanedContent = fileContent.components(separatedBy: "\r\n--").first ?? fileContent
                    
                    if let fileData = cleanedContent.data(using: .utf8) {
                        logger.debug("📁 CONN-\(connectionId): File extracted from multipart, size: \(fileData.count)")
                        return fileData
                    }
                }
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

protocol WorkingHTTPServerDelegate: AnyObject {
    func httpServer(_ server: WorkingHTTPServer, didChangeState isRunning: Bool)
    func httpServer(_ server: WorkingHTTPServer, didEncounterError error: String)
    func httpServer(_ server: WorkingHTTPServer, didProcessRequest stats: RequestStats)
}