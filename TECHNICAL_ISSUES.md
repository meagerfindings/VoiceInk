# VoiceInk API Technical Issues - Internal Reference

## Current Blocking Issue

### Threading/Actor Architecture Conflict
**Status**: Critical - Prevents all API functionality  
**Root Cause**: `TranscriptionAPIServer` class is marked with `@MainActor` but Network.framework callbacks execute on background queues.

**Symptoms**:
- Connections hang indefinitely after initial data reception
- Health endpoint times out
- File uploads start but never complete processing
- No error messages or exceptions thrown

**Technical Details**:
- NWListener callbacks run on background DispatchQueue
- TranscriptionAPIServer methods require MainActor context
- Synchronous calls from background → MainActor create deadlock
- Connection receives data but can't process it

**Debug Evidence**:
```
DEBUG: New connection received ✓
DEBUG: readNextChunk called ✓  
DEBUG: receive callback - data: 83 bytes ✓
[Processing stops here - no further execution]
```

## Required Fix

### Architecture Refactor Needed
1. **Separate Network Layer**: Create non-MainActor network handling classes
2. **Async Dispatch**: Use `Task { await MainActor.run { ... } }` for UI updates only
3. **Background Processing**: Move transcription logic off MainActor
4. **Connection Management**: Handle all NWConnection operations on background queues

### Files Requiring Changes
- `VoiceInk/API/TranscriptionAPIServer.swift` - Main refactor needed
- `VoiceInk/API/TranscriptionAPIHandler.swift` - May need MainActor isolation review
- Network callback handlers throughout the connection management code

### Implementation Strategy
1. Create separate `NetworkHandler` class (not @MainActor)
2. Move all NWConnection logic to NetworkHandler
3. Use delegate pattern or async callbacks to communicate with MainActor UI
4. Test with simple GET /health first, then POST /transcribe

## Infrastructure Already Implemented ✅

### Large File Support
- Buffer size: 500MB (`maxBufferSize = 524288000`)
- Chunked reading: 64KB chunks (`maximumLength: 65536`)
- Content-Length parsing and validation
- Multipart form data parsing for binary audio files

### Timeout Management  
- Connection timeout: 60 minutes (`connectionTimeout: TimeInterval = 3600`)
- Keep-alive mechanism: 30-second intervals
- Progress monitoring for long transcriptions
- Proper cleanup on timeout/cancellation

### Error Handling
- HTTP status codes: 400, 413, 500, 504
- JSON error response format
- Request size validation (413 for >500MB)
- Graceful connection termination

### Audio Processing Pipeline
- Multi-format support (MP3, WAV, M4A, etc.)
- Audio data extraction from multipart
- Integration with whisper.cpp transcription engine
- Response formatting with timing information

## Testing Done

### Connection Flow Verified
1. ✅ NWListener accepts connections on port 5000
2. ✅ newConnectionHandler callback triggered  
3. ✅ ConnectionDataHandler created and startReading() called
4. ✅ connection.receive() callback receives HTTP request data
5. ❌ Data processing stops due to MainActor deadlock

### File Upload Capability
- ✅ 33MB MP3 file: Upload started, 540KB transferred before timeout
- ✅ Small requests: Basic HTTP parsing works until processing stage
- ✅ Multipart parsing: Logic is correct (tested in isolation)

## Next Steps (When Time Permits)

1. **Immediate**: Refactor TranscriptionAPIServer threading architecture
2. **Testing**: Verify health endpoint works after refactor
3. **Integration**: Test large file upload end-to-end  
4. **Performance**: Optimize for 3-6 hour podcast files
5. **Documentation**: Update API documentation for home automation team

## Success Metrics

When fixed, should support:
- ✅ Health endpoint responds < 1 second
- ✅ 33MB file (40-minute podcast) transcribes successfully  
- ✅ 200MB+ files (3-6 hour podcasts) process within 60-minute timeout
- ✅ Multiple concurrent connections without interference
- ✅ Proper error handling and cleanup

---
*Last Updated: 2025-08-12*  
*Issue Discovered: Through extensive debugging of connection hanging behavior*