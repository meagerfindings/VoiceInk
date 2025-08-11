# VoiceInk Branch Comparison

## Current Branches

### 1. `feature/api-server` (Original API Branch)
**Status**: ✅ **WORKING** - Simple and functional

**Features**:
- Basic API server on port 7777 (default)
- Simple transcription endpoint `/api/transcribe`
- Health check endpoint `/health`
- No diarization support
- No auto-start

**Pros**:
- Simple, clean implementation
- No complex diarization logic
- Builds and runs without issues
- Stable for basic transcription needs

**Cons**:
- Requires manual start from Settings > API
- Port 7777 (not the requested 5000)
- No speaker diarization capability

**How to use**:
```bash
git checkout feature/api-server
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug build
# Start VoiceInk, go to Settings > API, click Start Server
curl -X POST http://localhost:7777/api/transcribe -F "file=@audio.wav"
```

### 2. `feature/speaker-diarization`
**Status**: ⚠️ Partially working - Has diarization infrastructure but speaker detection not functional

**Features**:
- All features from api-server branch
- Added TDRZ model support
- Diarization parameter extraction
- API Diarization Model selection in Settings
- Speaker turn detection infrastructure

**Issues**:
- Speaker identification returns only SPEAKER_UNKNOWN
- Actual speaker separation not working
- More complex codebase

### 3. `feature/remove-license-check` (Current Branch)
**Status**: ✅ **WORKING** for regular transcription, ⚠️ Diarization not functional

**Features**:
- Merged both api-server and speaker-diarization branches
- License checks removed
- Port changed to 5000
- Auto-start API server on app launch
- All diarization infrastructure (but not working)

**Current state after our fixes**:
- ✅ Builds successfully
- ✅ Regular API transcription works
- ✅ Auto-starts on port 5000
- ⚠️ Diarization parameters extracted but speaker detection fails

## Recommendation

### Option 1: Use Simple API (Recommended)
**Switch to `feature/api-server` branch** if you just need basic transcription API:
```bash
git checkout feature/api-server
# Build and use - simple and reliable
```

You would need to:
1. Manually change port to 5000 if needed
2. Add auto-start feature if desired
3. Skip diarization completely

### Option 2: Continue with Current Branch
**Stay on `feature/remove-license-check`** if you want:
- Auto-start on port 5000 (already working)
- Regular transcription (already working)
- Future possibility of fixing diarization

To disable diarization code paths, you could:
1. Simply not send diarization parameters in API requests
2. Remove the DiarizationParameterExtractor references
3. Keep using it as-is (diarization params are ignored if model not configured)

### Option 3: Cherry-pick Best Features
Create a new clean branch with only what works:
```bash
git checkout -b feature/api-simple main
git cherry-pick <commit-with-api-server>
# Then manually add:
# - Port 5000 change
# - Auto-start feature
# - Skip all diarization code
```

## Quick Fixes for Current Branch

If staying on `feature/remove-license-check`, to clean up:

```bash
# Remove diarization UI if not needed
rm VoiceInk/API/DiarizationParameterExtractor.swift
# Comment out diarization code in TranscriptionAPIHandler.swift
# Remove apiDiarizationModel from Settings
```

## Summary

- **Original `feature/api-server`**: Simple, working, but needs manual start and uses port 7777
- **Current `feature/remove-license-check`**: Has everything including auto-start on port 5000, transcription works, diarization doesn't
- **Best approach**: Either use the simple API branch or stay with current and ignore diarization features

The regular transcription API is working perfectly on all branches. The only issue is with speaker diarization, which can be ignored or removed if not needed.