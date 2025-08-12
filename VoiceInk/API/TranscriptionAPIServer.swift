import Foundation
import Network
import os

// MARK: - Supporting Classes

// Protocol for network manager to communicate with UI coordinator
protocol NetworkManagerDelegate: AnyObject {
    func networkManager(_ manager: NetworkManager, didChangeState isRunning: Bool)
    func networkManager(_ manager: NetworkManager, didEncounterError error: String)
    func networkManager(_ manager: NetworkManager, didProcessRequest stats: RequestStats)
}

struct RequestStats {
    let method: String
    let path: String
    let processingTime: TimeInterval
    let success: Bool
}

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
        logger.debug("New connection received")
        
        // Start connection on background queue
        connection.start(queue: queue)
        
        // Create connection handler
        let connectionHandler = ConnectionHandler(
            connection: connection, 
            transcriptionProcessor: transcriptionProcessor,
            networkManager: self
        )
        connectionHandler.startReading()
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
    
    init(connection: NWConnection, transcriptionProcessor: TranscriptionProcessor, networkManager: NetworkManager) {
        self.connection = connection
        self.transcriptionProcessor = transcriptionProcessor
        self.networkManager = networkManager
    }
    
    func startReading() {
        readNextChunk()
    }
    
    private func readNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logger.error("Connection error: \(error.localizedDescription)")
                self.connection.cancel()
                return
            }
            
            // Append any received data
            if let data = data {
                self.accumulatedData.append(data)
                
                // Check if buffer is too large
                if self.accumulatedData.count > self.maxBufferSize {
                    self.logger.error("Request too large: \(self.accumulatedData.count) bytes")
                    self.sendErrorResponse(statusCode: 413, message: "Request Entity Too Large")
                    return
                }
                
                // Try to parse headers if we haven't yet
                if self.headerEndIndex == nil {
                    if let separator = "\r\n\r\n".data(using: .utf8),
                       let range = self.accumulatedData.range(of: separator) {
                        self.headerEndIndex = range.upperBound
                        
                        // Parse Content-Length from headers
                        let headerData = self.accumulatedData.subdata(in: 0..<range.lowerBound)
                        if let headers = String(data: headerData, encoding: .utf8) {
                            self.parseContentLength(from: headers)
                            
                            // For GET requests with no body, process immediately
                            if headers.contains("GET /health") && !self.isRequestProcessed {
                                self.isRequestProcessed = true
                                self.processHealthRequest()
                                return
                            } else if headers.contains("GET ") && !self.isRequestProcessed {
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
                    
                    if currentBodyLength >= expectedLength && !self.isRequestProcessed {
                        // We have all the data, process it
                        self.logger.info("Complete request received: \(self.accumulatedData.count) bytes total")
                        self.isRequestProcessed = true
                        self.processRequest()
                        return
                    }
                }
            }
            
            // Continue reading if not complete
            if !isComplete {
                self.readNextChunk()
            } else {
                // Connection completed - process what we have
                if self.accumulatedData.count > 0 && !self.isRequestProcessed {
                    self.isRequestProcessed = true
                    self.processRequest()
                } else {
                    self.logger.error("Connection closed with no data")
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
                    break
                }
            }
        }
    }
    
    private func processHealthRequest() {
        let startTime = Date()
        
        // Create simple health JSON string to avoid Content-Length miscalculation
        let healthJson = "{\"status\":\"healthy\",\"service\":\"VoiceInk API\",\"timestamp\":\(Date().timeIntervalSince1970)}"
        
        // Build complete HTTP response with correct Content-Length
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(healthJson.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(healthJson)"
        
        let responseData = response.data(using: .utf8) ?? Data()
        
        print("Sending health response: \(response.count) bytes")
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("Health response send error: \(error)")
            } else {
                print("Health response sent successfully")
            }
            
            // Report completion stats
            let processingTime = Date().timeIntervalSince(startTime)
            let stats = RequestStats(method: "GET", path: "/health", processingTime: processingTime, success: error == nil)
            self?.networkManager?.reportRequestCompletion(stats)
            
            // Immediate connection close
            self?.connection.cancel()
        })
    }
    
    private func processRequest() {
        let startTime = Date()
        
        // Find the header/body separator
        let separator = "\r\n\r\n".data(using: .utf8)!
        guard let separatorRange = accumulatedData.range(of: separator) else {
            logger.error("No header/body separator found")
            sendErrorResponse(statusCode: 400, message: "Invalid request")
            return
        }
        
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
        
        logger.info("Request: \(method) \(path)")
        
        // Extract body data
        let bodyStart = separatorRange.upperBound
        let bodyData = accumulatedData.subdata(in: bodyStart..<accumulatedData.count)
        
        // Route the request (health requests already handled in readNextChunk)
        Task {
            do {
                if method == "POST" && path == "/api/transcribe" {
                    try await handleTranscribeRequest(headers: headers, bodyData: bodyData, startTime: startTime)
                } else {
                    logger.error("Path not found: \(path)")
                    sendErrorResponse(statusCode: 404, message: "Not found")
                    
                    let processingTime = Date().timeIntervalSince(startTime)
                    let stats = RequestStats(method: method, path: path, processingTime: processingTime, success: false)
                    networkManager?.reportRequestCompletion(stats)
                }
            } catch {
                logger.error("Request processing failed: \(error.localizedDescription)")
                sendErrorResponse(statusCode: 500, message: error.localizedDescription)
                
                let processingTime = Date().timeIntervalSince(startTime)
                let stats = RequestStats(method: method, path: path, processingTime: processingTime, success: false)
                networkManager?.reportRequestCompletion(stats)
            }
        }
    }
    
    private func handleTranscribeRequest(headers: String, bodyData: Data, startTime: Date) async throws {
        // Extract the multipart boundary
        guard let boundary = extractBoundary(from: headers) else {
            sendErrorResponse(statusCode: 400, message: "Missing multipart boundary")
            return
        }
        
        // Parse multipart data from raw body
        guard let audioData = extractAudioDataFromRaw(bodyData: bodyData, boundary: boundary) else {
            logger.error("Failed to extract audio data from multipart. Body size: \(bodyData.count) bytes, Boundary: \(boundary)")
            sendErrorResponse(statusCode: 400, message: "No audio file found. Body size: \(bodyData.count) bytes")
            return
        }
        
        logger.info("Successfully extracted audio data: \(audioData.count) bytes")
        
        // Process the transcription using the transcription processor
        let result = try await transcriptionProcessor.transcribe(audioData: audioData)
        let processingTime = Date().timeIntervalSince(startTime)
        
        // Send response
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
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(data)
        
        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
    
    private func sendErrorResponse(statusCode: Int, message: String) {
        let json = """
        {"success":false,"error":{"code":"\(statusCode)","message":"\(message)"}}
        """
        
        let statusText = statusCode == 404 ? "Not Found" : 
                        statusCode == 400 ? "Bad Request" :
                        statusCode == 500 ? "Internal Server Error" :
                        statusCode == 413 ? "Payload Too Large" : "Error"
        
        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(json)"
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
}

/// Handles transcription processing on background queues
/// NOT @MainActor - accesses WhisperState using await MainActor.run
class TranscriptionProcessor {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "TranscriptionProcessor")
    
    private let whisperState: WhisperState
    private let apiHandler: TranscriptionAPIHandler
    
    init(whisperState: WhisperState) {
        self.whisperState = whisperState
        self.apiHandler = TranscriptionAPIHandler(whisperState: whisperState)
    }
    
    /// Transcribe audio data - runs on background queue, safely accesses MainActor state
    func transcribe(audioData: Data) async throws -> Data {
        logger.info("Starting transcription of \(audioData.count) bytes")
        
        // Use the existing TranscriptionAPIHandler which already handles MainActor access properly
        return try await apiHandler.transcribe(audioData: audioData)
    }
}

// MARK: - Main API Server Coordinator

/// API Server Coordinator - MainActor for UI state management only
@MainActor
class TranscriptionAPIServer: ObservableObject, NetworkManagerDelegate {
    private let logger = Logger(subsystem: "com.voiceink.api", category: "APICoordinator")
    
    @Published var isRunning = false
    @Published var port: Int = 5000
    @Published var lastError: String?
    
    // Network handling - runs on background queues
    private var networkManager: NetworkManager?
    private let transcriptionProcessor: TranscriptionProcessor
    private let whisperState: WhisperState
    
    // Stats tracking
    private var serverStartTime: Date?
    private var requestCount: Int = 0
    private var totalProcessingTime: TimeInterval = 0
    
    init(whisperState: WhisperState) {
        self.whisperState = whisperState
        self.transcriptionProcessor = TranscriptionProcessor(whisperState: whisperState)
        
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
        
        // Create and configure network manager
        let allowNetworkAccess = UserDefaults.standard.bool(forKey: "APIServerAllowNetworkAccess")
        networkManager = NetworkManager(
            port: port,
            allowNetworkAccess: allowNetworkAccess,
            transcriptionProcessor: transcriptionProcessor
        )
        networkManager?.delegate = self
        
        // Start network operations on background queue
        networkManager?.start()
        
        logger.info("API server coordinator starting on port \(self.port)")
    }
    
    func stop() {
        networkManager?.stop()
        networkManager = nil
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
    
    // MARK: - NetworkManagerDelegate
    
    func networkManager(_ manager: NetworkManager, didChangeState isRunning: Bool) {
        self.isRunning = isRunning
        if isRunning {
            lastError = nil
            logger.info("API server is ready on port \(self.port)")
        } else {
            logger.info("API server stopped")
        }
    }
    
    func networkManager(_ manager: NetworkManager, didEncounterError error: String) {
        lastError = error
        logger.error("API server error: \(error)")
    }
    
    func networkManager(_ manager: NetworkManager, didProcessRequest stats: RequestStats) {
        requestCount += 1
        totalProcessingTime += stats.processingTime
        logger.info("Processed \(stats.method) \(stats.path) - \(stats.success ? "SUCCESS" : "FAILED") in \(String(format: "%.2f", stats.processingTime * 1000))ms")
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
                enhancementEnabled: await MainActor.run { whisperState.enhancementService?.isEnhancementEnabled ?? false },
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
}