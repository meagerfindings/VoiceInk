# VoiceInk API Documentation

## Overview
VoiceInk provides a local HTTP API server for audio transcription. The API runs on port 5000 by default and supports multiple audio formats including MP3, WAV, M4A, and AIFF.

## Starting the API Server
1. Open VoiceInk application
2. Go to Settings → API Server
3. Toggle "Enable API Server" ON
4. The server will start on `http://localhost:5000`

## Endpoints

### 1. Health Check
**GET** `/health`

Check if the API server is running and get system information.

**Response:**
```json
{
  "status": "healthy",
  "service": "VoiceInk API",
  "version": "2.0.0",
  "timestamp": 1234567890,
  "system": {
    "platform": "macOS",
    "osVersion": "14.0",
    "processorCount": 8,
    "memoryUsageMB": 512.5,
    "uptimeSeconds": 3600
  },
  "api": {
    "endpoint": "http://localhost:5000",
    "port": 5000,
    "isRunning": true,
    "requestsServed": 42,
    "averageProcessingTimeMs": 1500
  },
  "transcription": {
    "currentModel": "Parakeet",
    "modelLoaded": true,
    "availableModels": ["Parakeet", "Whisper Base", "Whisper Small"],
    "enhancementEnabled": false,
    "wordReplacementEnabled": false
  }
}
```

### 2. Transcribe Audio
**POST** `/api/transcribe`

Transcribe an audio file to text.

**Request:**
- Method: `POST`
- Content-Type: `multipart/form-data`
- Body: Audio file with field name `file`

**Supported Audio Formats:**
- MP3 (.mp3)
- WAV (.wav)
- M4A (.m4a)
- AIFF (.aiff)
- AAC (.aac)
- FLAC (.flac)

**Example Request:**
```bash
curl -X POST \
  -F "file=@audio.mp3" \
  http://localhost:5000/api/transcribe
```

**Success Response:**
```json
{
  "success": true,
  "text": "This is the transcribed text from the audio file.",
  "metadata": {
    "duration": 30.5,
    "language": "en",
    "processingTime": 2.34,
    "transcriptionTime": 1.89,
    "enhanced": false,
    "model": "Parakeet",
    "replacementsApplied": false
  }
}
```

**Error Response:**
```json
{
  "success": false,
  "error": {
    "code": "NO_MODEL",
    "message": "No transcription model is currently loaded. Please load a model in VoiceInk before using the API."
  }
}
```

## Important Notes

### Model Requirements
- **A transcription model must be loaded** in VoiceInk before using the API
- Go to VoiceInk → Model Management to download and select a model
- Recommended models:
  - **Parakeet** - Fast, good accuracy, small size
  - **Whisper Small** - Balanced speed and accuracy
  - **Whisper Base** - Fastest, lower accuracy

### File Size Limits
- Maximum file size: 500MB
- Large files (>10MB) may take longer to process
- The API handles files up to 60MB efficiently (tested with 33MB podcasts)

### Audio File Cleanup
- Uploaded audio files are **automatically deleted** after transcription
- No audio data is retained on disk after the request completes
- This ensures privacy and prevents disk space issues

### Network Access
- By default, the API only accepts connections from `localhost`
- To allow network access:
  1. Go to Settings → API Server
  2. Toggle "Allow Network Access" ON
  3. The API will be accessible at `http://YOUR_IP:5000`
  4. **Security Warning:** Only enable this on trusted networks

### Error Codes
- `400` - Bad Request (missing file, invalid format)
- `404` - Endpoint not found
- `413` - File too large (>500MB)
- `500` - Internal server error

### Performance Tips
- First transcription after starting may be slower (model loading)
- Subsequent transcriptions are faster (model cached in memory)
- Response times vary by file size and selected model:
  - 30-second audio: ~1-3 seconds
  - 5-minute audio: ~5-15 seconds
  - 30-minute podcast: ~30-60 seconds

## Example Integration

### Python
```python
import requests

# Transcribe an audio file
with open('audio.mp3', 'rb') as f:
    files = {'file': f}
    response = requests.post('http://localhost:5000/api/transcribe', files=files)
    
result = response.json()
if result['success']:
    print(f"Transcription: {result['text']}")
    print(f"Duration: {result['metadata']['duration']}s")
else:
    print(f"Error: {result['error']['message']}")
```

### Node.js
```javascript
const FormData = require('form-data');
const fs = require('fs');
const axios = require('axios');

const form = new FormData();
form.append('file', fs.createReadStream('audio.mp3'));

axios.post('http://localhost:5000/api/transcribe', form, {
    headers: form.getHeaders()
})
.then(response => {
    if (response.data.success) {
        console.log('Transcription:', response.data.text);
    }
})
.catch(error => {
    console.error('Error:', error.response.data);
});
```

### Shell Script
```bash
#!/bin/bash

# Simple transcription script
AUDIO_FILE="$1"
API_URL="http://localhost:5000/api/transcribe"

if [ -z "$AUDIO_FILE" ]; then
    echo "Usage: $0 <audio_file>"
    exit 1
fi

# Send request and extract text
curl -s -X POST -F "file=@$AUDIO_FILE" "$API_URL" | \
    python3 -c "import sys, json; print(json.load(sys.stdin)['text'])"
```

## Troubleshooting

### API Server Won't Start
- Ensure no other service is using port 5000
- Check if VoiceInk has necessary permissions
- Try restarting VoiceInk

### "No Model Loaded" Error
1. Open VoiceInk
2. Go to Model Management
3. Download a model (e.g., Parakeet)
4. Select the model as active
5. Retry the API request

### Connection Refused
- Verify the API server is enabled in Settings
- Check the port number (default: 5000)
- Ensure firewall isn't blocking the connection

### Slow Transcription
- First request after startup is slower (model loading)
- Large files take proportionally longer
- Consider using a faster model (Parakeet or Whisper Base)

## Security Considerations
- The API has no authentication by default
- Only enable network access on trusted networks
- Audio files are deleted immediately after processing
- Consider using a reverse proxy with authentication for production use

## Support
For issues or questions about the VoiceInk API, please visit:
https://github.com/meagerfindings/VoiceInk