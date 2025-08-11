import Foundation
import Network
import os

/// HTTP API server for VoiceInk transcription services
@MainActor
class TranscriptionAPIServer: ObservableObject {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APIServer")
    
    @Published var isRunning = false
    @Published var port: Int = 5000
    @Published var lastError: String?
    
    private var listener: NWListener?
    private let handler: TranscriptionAPIHandler
    private let queue = DispatchQueue(label: "com.voiceink.api.server", qos: .userInitiated)
    
    // Stats tracking
    private var serverStartTime: Date?
    private var requestCount: Int = 0
    private var totalProcessingTime: TimeInterval = 0
    
    init(whisperState: WhisperState) {
        self.handler = TranscriptionAPIHandler(whisperState: whisperState)
        
        // Load saved settings
        self.port = UserDefaults.standard.integer(forKey: "APIServerPort")
        if self.port == 0 {
            self.port = 5000
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        serverStartTime = Date()
        requestCount = 0
        totalProcessingTime = 0
        
        // Ensure a model is loaded or selected
        Task { @MainActor in
            await ensureModelIsReady()
        }
        
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
    
    private func ensureModelIsReady() async {
        let whisperState = handler.whisperState
        
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
        
        // Read the HTTP request with larger buffer for audio files
        connection.receive(minimumIncompleteLength: 1, maximumLength: 10485760) { [weak self] data, _, isComplete, error in
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
        // Find the header/body separator
        let separator = "\r\n\r\n".data(using: .utf8)!
        guard let separatorRange = data.range(of: separator) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request")
            return
        }
        
        // Parse headers as UTF-8
        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request headers")
            return
        }
        
        // Parse HTTP request line
        let lines = headers.components(separatedBy: "\r\n")
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
        
        // Extract body data (raw, not converted to string)
        let bodyStart = separatorRange.upperBound
        let bodyData = data.subdata(in: bodyStart..<data.count)
        
        // Route the request
        if method == "POST" && path == "/api/transcribe" {
            await handleTranscribeRequest(headers: headers, bodyData: bodyData, connection: connection)
        } else if method == "GET" && path == "/health" {
            sendHealthResponse(connection: connection)
        } else {
            sendErrorResponse(connection: connection, statusCode: 404, message: "Not found")
        }
    }
    
    private func handleTranscribeRequest(headers: String, bodyData: Data, connection: NWConnection) async {
        // Extract the multipart boundary
        guard let boundary = extractBoundary(from: headers) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "Missing multipart boundary")
            return
        }
        
        // Parse multipart data from raw body
        guard let audioData = extractAudioDataFromRaw(bodyData: bodyData, boundary: boundary) else {
            sendErrorResponse(connection: connection, statusCode: 400, message: "No audio file found")
            return
        }
        
        // Process the transcription
        let startTime = Date()
        do {
            let result = try await handler.transcribe(audioData: audioData)
            let processingTime = Date().timeIntervalSince(startTime)
            
            // Update stats
            requestCount += 1
            totalProcessingTime += processingTime
            
            sendJSONResponse(connection: connection, data: result)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            sendErrorResponse(connection: connection, statusCode: 500, message: error.localizedDescription)
        }
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
                // Log content type if present for debugging
                if let contentType = AudioFormatDetector.extractContentType(from: headers) {
                    logger.info("File content-type: \(contentType)")
                }
                
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
    
    private func sendHealthResponse(connection: NWConnection) {
        Task {
            let healthData = await getHealthStatus()
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(healthData.count)\r
            Access-Control-Allow-Origin: *\r
            \r
            
            """
            
            var responseData = response.data(using: .utf8) ?? Data()
            responseData.append(healthData)
            
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    private func getHealthStatus() async -> Data {
        // Get current model info
        let currentModel = handler.whisperState.currentTranscriptionModel
        let modelLoaded = handler.whisperState.isModelLoaded
        let availableModels = handler.whisperState.availableModels.map { $0.name }
        
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
                uptimeSeconds: uptime
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
                enhancementEnabled: handler.whisperState.enhancementService?.isEnhancementEnabled ?? false,
                wordReplacementEnabled: UserDefaults.standard.bool(forKey: "IsWordReplacementEnabled")
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