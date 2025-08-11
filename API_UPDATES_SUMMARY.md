# VoiceInk API Server Updates Summary

## Overview
This document summarizes the updates made to the VoiceInk API server, focusing on fixing compilation errors, updating default configuration, and improving speaker diarization functionality.

## Changes Made

### 1. Fixed Compilation Errors
**Issue**: Build was failing due to Swift visibility modifiers and type mismatches.

**Files Modified**:
- `VoiceInk/Services/PolarService.swift`
  - Made `LicenseError` enum public
  - Made `errorDescription` property public to satisfy LocalizedError protocol

- `VoiceInk/API/TranscriptionAPIHandler.swift`
  - Fixed `currentModel` variable handling to avoid redeclaration
  - Properly handled optional unwrapping for model selection

- `VoiceInk/Views/Settings/APISettingsView.swift`
  - Fixed closure parameter naming from ambiguous `$0` to explicit `tdrzModel`

### 2. API Server Configuration Updates
**Changes**: Updated default port and added auto-start functionality.

**Files Modified**:
- `VoiceInk/API/TranscriptionAPIServer.swift`
  - Changed default port from 7777 to 5000
  - Updated init() to use port 5000 by default

- `VoiceInk/Views/Settings/APISettingsView.swift`
  - Changed default port display to "5000"
  
- `VoiceInk/VoiceInk.swift`
  - Added auto-start logic for API server on app launch
  - Checks UserDefaults "APIServerAutoStart" setting
  - Sets auto-start to true by default for new installations

### 3. Speaker Diarization Improvements
**Goal**: Enable proper speaker identification when using TDRZ (tinydiarize) models.

#### 3.1 Created Diarization Parameter Extractor
**New File**: `VoiceInk/API/DiarizationParameterExtractor.swift`
- Handles multipart form data parsing
- Extracts diarization parameters from API requests
- Supports fields: enable_diarization, diarization_mode, min_speakers, max_speakers, use_tinydiarize
- Fixed boundary parsing issues for large audio files

#### 3.2 Enhanced Transcription Handler
**File**: `VoiceInk/API/TranscriptionAPIHandler.swift`

**Major Changes**:
- Added automatic TDRZ model detection
- When a TDRZ model is selected, automatically enables tinydiarize
- Implemented `transcribeWithSegments` method for detailed segment extraction
- Added speaker turn processing:
  - Converts boolean speaker turn flags to speaker IDs (SPEAKER_00, SPEAKER_01, etc.)
  - Embeds speaker labels in segment text for downstream processing
- Added comprehensive debug logging throughout the pipeline

**Key Code Additions**:
```swift
// Automatic TDRZ detection
if diarizationModel.name.lowercased().contains("tdrz") {
    diarizationParams.useTinydiarize = true
}

// Speaker turn processing
for (index, segment) in detailedSegments.enumerated() {
    if index > 0 && segment.speakerTurn {
        currentSpeaker = (currentSpeaker + 1) % 4
    }
    let speakerLabel = "SPEAKER_\(String(format: "%02d", currentSpeaker))"
    // Embed speaker in segment text
}
```

#### 3.3 Model Updates
**File**: `VoiceInk/Models/DiarizationModels.swift`
- Made `useTinydiarize` property mutable (changed from `let` to `var`)
- Allows runtime modification when TDRZ models are detected

#### 3.4 Health Response Enhancement
**File**: `VoiceInk/API/Models/HealthResponse.swift`
- Added `apiDiarizationModel` field to TranscriptionInfo
- Provides visibility into which diarization model is configured

### 4. Testing Infrastructure
**Created/Updated Test Scripts**:
- `test_api_curl.sh`: Comprehensive API testing script
  - Tests health endpoint
  - Tests basic transcription
  - Tests transcription with diarization
  - Properly orders multipart fields (parameters before file)

## Current Status

### Working Features ✅
- API server runs on port 5000
- API server auto-starts when app launches
- Build compiles without errors
- **Regular API transcription works perfectly**
- Diarization parameter extraction from multipart requests
- Debug logging to `/tmp/voiceink_debug.log`

### Configuration Required ⚠️
- **API Diarization Model must be selected in VoiceInk Settings**
  - Go to Settings > API > API Diarization Model
  - Select a TDRZ model (e.g., "Small TDRZ (English)")
  - Without this, diarization requests will use the regular model

### Known Issues When Configured ⚠️
- Speaker identification shows only "SPEAKER_UNKNOWN" 
- Actual speaker separation not occurring (detects 1 speaker instead of multiple)
- Speaker turn flags from whisper.cpp not being properly set

### Potential Causes
1. TDRZ model file may not be properly configured for speaker detection
2. whisper.cpp implementation might need additional parameters
3. Audio files might not have clear enough speaker changes
4. The tinydiarize feature might require specific whisper.cpp compilation flags

## Testing Instructions

### 1. Start API Server
The API server should start automatically when VoiceInk launches. If not:
1. Open VoiceInk
2. Go to Settings > API
3. Click "Start Server"
4. Verify it's running on port 5000

### 2. Test Basic Transcription
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@test_audio.wav"
```

### 3. Test Diarization
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "enable_diarization=true" \
  -F "diarization_mode=balanced" \
  -F "min_speakers=2" \
  -F "max_speakers=4" \
  -F "file=@conversation.wav"
```

### 4. Check Debug Logs
```bash
tail -f /tmp/voiceink_debug.log
```

## Next Steps

To fully resolve the speaker diarization issue:

1. **Verify TDRZ Model**: Ensure the TDRZ model file is the correct version with speaker detection capabilities
2. **Check whisper.cpp Build**: Verify whisper.cpp was compiled with tinydiarize support
3. **Test with Different Audio**: Try audio files with very distinct speaker changes
4. **Review whisper.cpp Parameters**: Check if additional parameters are needed for the tdrz_enable flag
5. **Implement Fallback**: Consider implementing alternative diarization methods (stereo channel separation, external services)

## File Summary

### Modified Files
- `VoiceInk/Services/PolarService.swift`
- `VoiceInk/API/TranscriptionAPIHandler.swift`
- `VoiceInk/API/TranscriptionAPIServer.swift`
- `VoiceInk/Views/Settings/APISettingsView.swift`
- `VoiceInk/VoiceInk.swift`
- `VoiceInk/Models/DiarizationModels.swift`
- `VoiceInk/API/Models/HealthResponse.swift`
- `VoiceInk/Whisper/LibWhisper.swift`

### New Files
- `VoiceInk/API/DiarizationParameterExtractor.swift`
- `test_api_curl.sh`
- Various test audio files (conversation.wav, test_short.wav, etc.)

## Notes
- All changes maintain backward compatibility
- No breaking changes to existing API endpoints
- Debug logging can be disabled in production
- The implementation is modular and can be extended with additional diarization methods