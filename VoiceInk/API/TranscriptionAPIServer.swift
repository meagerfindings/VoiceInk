import Foundation
import Network
import os

/// HTTP API server for VoiceInk transcription services
@MainActor
class TranscriptionAPIServer: ObservableObject {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APIServer")
    
    @Published var isRunning = false
    @Published var port: Int = 8080
    @Published var lastError: String?
    
    private var listener: NWListener?
    private let handler: TranscriptionAPIHandler
    private let queue = DispatchQueue(label: "com.voiceink.api.server", qos: .userInitiated)
    
    init(whisperState: WhisperState) {
        self.handler = TranscriptionAPIHandler(whisperState: whisperState)
        
        // Load saved settings
        self.port = UserDefaults.standard.integer(forKey: "APIServerPort")
        if self.port == 0 {
            self.port = 8080
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        // Only bind to localhost by default for security
        let host = UserDefaults.standard.bool(forKey: "APIServerAllowNetworkAccess") ? nil : NWEndpoint.Host("127.0.0.1")
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            
            if let host = host {
                listener?.parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleStateUpdate(state)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            
            listener?.start(queue: queue)
            logger.info("API server starting on port \(self.port)")
            
        } catch {
            logger.error("Failed to start API server: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        logger.info("API server stopped")
    }
    
    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            logger.info("API server is ready on port \(self.port)")
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
            logger.error("API server failed: \(error.localizedDescription)")
        case .cancelled:
            isRunning = false
            logger.info("API server cancelled")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self,
                  let data = data,
                  !data.isEmpty else {
                connection.cancel()
                return
            }
            
            Task {
                await self.processRequest(data: data, connection: connection)
            }
        }
    }
    
    private func processRequest(data: Data, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        // Parse HTTP request
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        
        // Route the request
        if method == "POST" && path == "/api/transcribe" {
            await handleTranscribeRequest(request: request, connection: connection)
        } else if method == "GET" && path == "/health" {
            sendHealthResponse(connection: connection)
        } else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Not found")
        }
    }
    
    private func handleTranscribeRequest(request: String, connection: NWConnection) async {
        // Extract the multipart boundary
        guard let boundary = extractBoundary(from: request) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Missing multipart boundary")
            return
        }
        
        // Find where the body starts (after the empty line)
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request format")
            return
        }
        
        let bodyStart = request.index(bodyRange.upperBound, offsetBy: 0)
        let body = String(request[bodyStart...])
        
        // Parse multipart data
        guard let audioData = extractAudioData(from: body, boundary: boundary) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "No audio file found")
            return
        }
        
        // Process the transcription
        do {
            let result = try await handler.transcribe(audioData: audioData)
            sendJSONResponse(connection: connection, data: result)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            sendErrorResponse(connection: connection, statusCode: 500, message: error.localizedDescription)
        }
    }
    
    private func extractBoundary(from request: String) -> String? {
        for line in request.components(separatedBy: "\r\n") {
            if line.lowercased().contains("content-type:") && line.contains("boundary=") {
                let parts = line.components(separatedBy: "boundary=")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }
    
    private func extractAudioData(from body: String, boundary: String) -> Data? {
        // This is a simplified multipart parser
        // In production, you'd want a more robust parser
        let delimiter = "--\(boundary)"
        let parts = body.components(separatedBy: delimiter)
        
        for part in parts {
            if part.contains("Content-Disposition: form-data") && part.contains("name=\"file\"") {
                // Find where the file data starts
                if let dataRange = part.range(of: "\r\n\r\n") {
                    let dataStart = part.index(dataRange.upperBound, offsetBy: 0)
                    let fileDataString = String(part[dataStart...])
                    
                    // Remove any trailing boundary markers
                    let trimmed = fileDataString.replacingOccurrences(of: "\r\n--\(boundary)--\r\n", with: "")
                                               .replacingOccurrences(of: "\r\n--\(boundary)\r\n", with: "")
                    
                    return trimmed.data(using: .utf8)
                }
            }
        }
        return nil
    }
    
    private func sendHealthResponse(connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Access-Control-Allow-Origin: *\r
        \r
        {"status":"healthy","service":"VoiceInk API","version":"1.0.0"}
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendJSONResponse(connection: NWConnection, data: Data) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Access-Control-Allow-Origin: *\r
        \r
        
        """
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(data)
        
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendErrorResponse(connection: NWConnection, statusCode: Int, message: String) {
        let json = """
        {"success":false,"error":{"code":"\(statusCode)","message":"\(message)"}}
        """
        
        let statusText = statusCode == 404 ? "Not Found" : 
                        statusCode == 400 ? "Bad Request" :
                        statusCode == 500 ? "Internal Server Error" : "Error"
        
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(json.count)\r
        Access-Control-Allow-Origin: *\r
        \r
        \(json)
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}