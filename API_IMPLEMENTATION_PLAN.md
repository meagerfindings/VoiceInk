# VoiceInk API Server Implementation Plan

## Overview
Add an HTTP API server to VoiceInk that allows external applications to send audio files for transcription using VoiceInk's existing transcription pipeline.

## Architecture Decision
- Use a lightweight Swift HTTP server (either URLSession-based or Swift NIO)
- Integrate with existing VoiceInk transcription services
- Maintain all current features (model selection, enhancement, word replacement)

## TODO List

### Phase 1: Core API Server Setup
- [ ] Research and choose HTTP server approach for macOS Swift app
  - Option 1: URLSession with local HTTP server
  - Option 2: Swift NIO for more robust server
  - Option 3: Lightweight framework like Swifter
- [ ] Create `VoiceInk/API/` directory structure
- [ ] Implement basic HTTP server class (`TranscriptionAPIServer.swift`)
- [ ] Add server lifecycle management (start/stop/status)

### Phase 2: API Endpoint Implementation
- [ ] Create `/api/transcribe` POST endpoint handler
- [ ] Implement multipart/form-data parsing for file uploads
- [ ] Create request/response models
- [ ] Add error handling and status codes
- [ ] Implement JSON response formatting

### Phase 3: Transcription Pipeline Integration
- [ ] Create bridge between API handler and existing `AudioTranscriptionManager`
- [ ] Handle temporary file storage for uploaded audio
- [ ] Map API parameters to VoiceInk settings:
  - Model selection (use current or override)
  - Language selection
  - Enhancement options
  - Word replacement settings
- [ ] Ensure proper cleanup of temporary files

### Phase 4: Settings and Configuration
- [ ] Add API section to VoiceInk settings UI
  - [ ] Enable/disable API server toggle
  - [ ] Port configuration (default: 8080)
  - [ ] Authentication token field (optional)
  - [ ] Local-only vs network access option
- [ ] Store settings in UserDefaults
- [ ] Add server auto-start option on app launch

### Phase 5: Security and Performance
- [ ] Implement optional API key authentication
- [ ] Add request size limits (max file size)
- [ ] Implement basic rate limiting
- [ ] Add CORS headers for web access
- [ ] Ensure server only binds to localhost by default

### Phase 6: Testing and Documentation
- [ ] Create test client script (Python/curl examples)
- [ ] Test with various audio formats
- [ ] Test error cases (invalid files, missing parameters)
- [ ] Write API documentation with examples
- [ ] Add API status indicator to VoiceInk UI

## API Specification

### Endpoint: POST /api/transcribe

#### Request Format
```
Content-Type: multipart/form-data

Parameters:
- file: Audio file (required) - WAV, MP3, M4A, etc.
- model: String (optional) - Override current model selection
- language: String (optional) - Language code (e.g., "en", "es")
- enhance: Boolean (optional) - Apply AI enhancement
- apply_replacements: Boolean (optional) - Apply word replacements
```

#### Response Format
```json
{
  "success": true,
  "text": "Original transcribed text",
  "enhanced_text": "AI enhanced version (if requested)",
  "metadata": {
    "model": "whisper-base",
    "language": "en",
    "duration": 10.5,
    "processing_time": 2.34,
    "enhanced": false,
    "replacements_applied": true
  }
}
```

#### Error Response
```json
{
  "success": false,
  "error": {
    "code": "INVALID_AUDIO_FILE",
    "message": "The uploaded file is not a valid audio format"
  }
}
```

## File Structure
```
VoiceInk/
├── API/
│   ├── TranscriptionAPIServer.swift       # Main server class
│   ├── TranscriptionAPIHandler.swift      # Request handling
│   ├── Models/
│   │   ├── TranscriptionRequest.swift     # Request model
│   │   └── TranscriptionResponse.swift    # Response model
│   └── Utilities/
│       ├── MultipartParser.swift          # Parse multipart data
│       └── APIAuthentication.swift        # Auth middleware
├── Views/
│   └── Settings/
│       └── APISettingsView.swift          # API configuration UI
```

## Implementation Notes

### Server Lifecycle
1. Server starts when enabled in settings
2. Runs on background thread to not block UI
3. Gracefully shuts down when app quits
4. Shows status in menu bar or settings

### Integration Points
- Use existing `WhisperState` for model management
- Leverage `AudioTranscriptionManager` for processing
- Apply same word replacements via `WordReplacementService`
- Use configured `AIEnhancementService` if enabled

### Example Usage
```bash
# Basic transcription
curl -X POST http://localhost:8080/api/transcribe \
  -F "file=@audio.wav"

# With options
curl -X POST http://localhost:8080/api/transcribe \
  -F "file=@audio.mp3" \
  -F "enhance=true" \
  -F "language=en"

# With authentication (if enabled)
curl -X POST http://localhost:8080/api/transcribe \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -F "file=@audio.wav"
```

## Future Enhancements
- WebSocket support for real-time transcription
- Batch processing endpoint
- Transcription history API
- Model management endpoints
- Status/health check endpoint
- Metrics and usage statistics

## Questions to Resolve
1. Should the API server be a separate process or integrated into the main app?
2. Should we support async/webhook callbacks for long transcriptions?
3. What level of API compatibility with OpenAI Whisper API do we want?
4. Should we add a queue system for multiple concurrent requests?

## Success Criteria
- [ ] External apps can send audio files and receive transcriptions
- [ ] API uses the same models and settings as the GUI
- [ ] Server doesn't impact normal VoiceInk usage
- [ ] Clear documentation and examples provided
- [ ] Security measures prevent abuse