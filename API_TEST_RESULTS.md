# VoiceInk API Test Results

## Test Environment
- **Date**: 2025-08-09
- **Branch**: feature/remove-license-check
- **Port**: 5000
- **Status**: API server needs manual activation

## Current Status

### ❌ API Server Not Running
The API server is not currently listening on port 5000. The server needs to be manually started through the VoiceInk UI.

### How to Start the API Server

1. **In VoiceInk Application**:
   - Open Settings/Preferences
   - Navigate to "API" section
   - Configure port to `5000`
   - Toggle "Allow Network Access" if needed
   - Click "Start Server" button
   - Verify status shows "Running"

2. **Once Started, the following endpoints will be available**:
   - `http://localhost:5000/health` - Health check endpoint
   - `http://localhost:5000/api/transcribe` - Transcription endpoint

## Test Files Created

### 1. Test Audio Files
- **test_audio.wav**: Simple counting audio for basic transcription
- **conversation.wav**: Multi-speaker conversation for diarization testing

### 2. Test Scripts
- **test_api.py**: Comprehensive test suite (requires requests library)
- **test_api_simple.py**: Simple test using only standard library

## Test Plan

### 1. Health Check Test
```bash
curl http://localhost:5000/health | jq .
```

Expected Response:
```json
{
  "status": "healthy",
  "service": "VoiceInk API",
  "version": "1.0.0",
  "transcription": {
    "currentModel": "ggml-base.en",
    "modelLoaded": true,
    "availableProviders": ["local", "openai", "groq", ...]
  },
  "api": {
    "isRunning": true,
    "requestsServed": 0,
    "uptime": 10.5
  }
}
```

### 2. Basic Transcription Test
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@test_audio.wav"
```

Expected Response:
```json
{
  "success": true,
  "text": "One, two, three, four, five.",
  "metadata": {
    "model": "ggml-base.en",
    "provider": "local",
    "processingTime": 1.2,
    "duration": 3.0
  }
}
```

### 3. Diarization Test
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@conversation.wav" \
  -F "enable_diarization=true" \
  -F "diarization_mode=balanced" \
  -F "min_speakers=2" \
  -F "max_speakers=4"
```

Expected Response:
```json
{
  "success": true,
  "text": "Full transcription text...",
  "speakers": ["SPEAKER_1", "SPEAKER_2"],
  "numSpeakers": 2,
  "segments": [
    {
      "speaker": "SPEAKER_1",
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, how are you today?"
    },
    {
      "speaker": "SPEAKER_2",
      "start": 2.5,
      "end": 4.0,
      "text": "I'm doing well, thank you!"
    }
  ],
  "textWithSpeakers": "SPEAKER_1: Hello, how are you today?\nSPEAKER_2: I'm doing well, thank you!",
  "metadata": {
    "diarizationMethod": "balanced",
    "processingTime": 5.2,
    "transcriptionTime": 1.5,
    "diarizationTime": 3.7
  }
}
```

### 4. Tinydiarize Test (Requires TDRZ Model)
First, load a TDRZ model in VoiceInk (e.g., "Small TDRZ (English)"), then:

```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@conversation.wav" \
  -F "enable_diarization=true" \
  -F "use_tinydiarize=true"
```

## Next Steps

1. **Start the API Server**:
   - Open VoiceInk Settings
   - Navigate to API section
   - Set port to 5000
   - Click "Start Server"

2. **Run Tests**:
   ```bash
   # Simple test
   python3 test_api_simple.py
   
   # Or comprehensive test (if requests is installed)
   python3 test_api.py
   ```

3. **Verify Results**:
   - Check that health endpoint returns server status
   - Verify basic transcription works
   - Test diarization with conversation audio
   - If TDRZ model loaded, test tinydiarize

## Known Issues

1. **API Server Manual Start Required**: The API server doesn't auto-start with the application. It must be manually started through the Settings UI.

2. **Port Configuration**: Ensure port 5000 is not in use by other services.

3. **Model Loading**: For diarization tests, appropriate models must be loaded:
   - Standard diarization: Any local model
   - Tinydiarize: TDRZ models only (e.g., ggml-small.en-tdrz)

## Test Script Usage

### test_api_simple.py (No Dependencies)
```bash
python3 test_api_simple.py
```

### test_api.py (Requires requests)
```bash
# Install requests if needed
pip3 install requests

# Run tests
python3 test_api.py
```

Both scripts will test:
- Health check endpoint
- Basic transcription
- Diarization (if supported)
- Tinydiarize (if TDRZ model loaded)