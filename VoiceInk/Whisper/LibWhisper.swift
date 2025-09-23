import Foundation
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    // Keep a handle to the abort deadline so we can cancel from the outside
    private var abortDeadlinePtr: UnsafeMutablePointer<Double>?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    // Static C-ABI callback used by ggml/whisper to determine if a computation should be aborted
    private static let abortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { userData in
        guard let userData = userData else { return false }
        let deadlineTS = userData.assumingMemoryBound(to: Double.self).pointee
        let nowTS = Date().timeIntervalSince1970
        // Abort when the current time exceeds the deadline
        return nowTS > deadlineTS
    }

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Read language directly from UserDefaults
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
            params.language = languageCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            languageCString = nil
            params.language = nil
        }
        
        if prompt != nil {
            promptCString = Array(prompt!.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }
        
        // Avoid realtime printing from whisper.cpp (the library itself advises against it)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        // Install an abort callback so we can reliably stop runaway computations
        // Compute a per-call time budget based on audio length with safe caps (configurable)
        let estimatedSeconds = max(0.0, Double(samples.count) / 16_000.0)
        let configuredMultiplier = UserDefaults.standard.object(forKey: "WhisperAbortMultiplier") as? Double ?? 8.0
        let configuredMaxCap = UserDefaults.standard.object(forKey: "WhisperAbortMaxSeconds") as? Double ?? 900.0 // 15 minutes
        
        // Reduce timeout for small files to prevent infinite loops
        let multiplier: Double
        let maxCap: Double
        if estimatedSeconds < 45 {
            multiplier = max(1.0, min(4.0, configuredMultiplier)) // Cap at 4x for small files
            maxCap = max(60.0, min(300.0, configuredMaxCap)) // Cap at 5 minutes for small files
        } else {
            multiplier = max(1.0, configuredMultiplier)
            maxCap = max(60.0, configuredMaxCap)
        }
        
        let timeBudgetSeconds = min(maxCap, max(20.0, estimatedSeconds * multiplier))
        let deadlineTimestamp = Date().addingTimeInterval(timeBudgetSeconds).timeIntervalSince1970
        let deadlinePtr = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        deadlinePtr.initialize(to: deadlineTimestamp)
        self.abortDeadlinePtr = deadlinePtr
        params.abort_callback = WhisperContext.abortCallback
        params.abort_callback_user_data = UnsafeMutableRawPointer(deadlinePtr)

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.object(forKey: "IsVADEnabled") as? Bool ?? true
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }
        
        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                logger.error("Failed to run whisper_full (aborted or error). VAD enabled: \(params.vad)")
                success = false
            }
        }
        
        // Clean up abort user data
        if let ptr = abortDeadlinePtr {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            abortDeadlinePtr = nil
        }
        
        languageCString = nil
        promptCString = nil
        
        return success
    }

    // Request immediate abort of any in-flight whisper_full() by setting deadline to now
    func requestAbortNow() {
        if let ptr = abortDeadlinePtr {
            ptr.pointee = Date().timeIntervalSince1970 - 1.0
            logger.info("Abort requested: deadline set to now")
        } else {
            logger.info("Abort requested: no active computation")
        }
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)
        
        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)
        
        return whisperContext
    }
    
    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        logger.info("Running on the simulator, using CPU")
        #else
        params.flash_attn = true // Enable flash attention for Metal
        logger.info("Flash attention enabled for Metal")
        #endif
        
        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("Couldn't load model at \(path)")
            throw WhisperStateError.modelLoadFailed
        }
    }
    
    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
