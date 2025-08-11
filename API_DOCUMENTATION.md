# VoiceInk API Documentation

## Overview
VoiceInk provides a local HTTP API server that enables external applications to use its transcription capabilities. The API server runs locally on your machine and provides a simple REST interface for audio transcription.

## Features
- Local transcription using whisper.cpp models
- Cloud transcription services (OpenAI, Groq, Deepgram, etc.)
- Support for multiple audio formats
- AI enhancement capabilities
- Word replacement processing
- Health check endpoint
- Optional authentication via API token

## Getting Started

### Starting the API Server

1. **Launch VoiceInk** - The API server auto-starts when the app launches (default behavior)
2. **Manual Control** - Go to Settings > API to manually start/stop the server
3. **Default Port** - The server runs on port 5000 by default (configurable)

### Configuration

In VoiceInk Settings > API:
- **Port**: Default 5000 (configurable)
- **Auto-start on Launch**: Enabled by default
- **Allow Network Access**: Disabled by default (localhost only)
- **API Token**: Optional authentication token

## API Endpoints

### 1. Health Check

Check if the API server is running and get system information.

**Endpoint**: `GET /health`

**Response**:
```json
{
  "status": "healthy",
  "service": "VoiceInk API",
  "version": "1.50",
  "timestamp": 1709123456.789,
  "system": {
    "platform": "macOS",
    "osVersion": "14.0",
    "processorCount": 8,
    "memoryUsageMB": 256.5,
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
    "currentModel": "ggml-base.en",
    "modelLoaded": true,
    "availableModels": ["ggml-base.en", "ggml-small.en"],
    "enhancementEnabled": true,
    "wordReplacementEnabled": true
  },
  "capabilities": [
    "speech-to-text",
    "multi-model-support",
    "ai-enhancement",
    "word-replacement",
    "local-transcription",
    "cloud-transcription"
  ]
}
```

### 2. Transcribe Audio

Transcribe an audio file to text.

**Endpoint**: `POST /api/transcribe`

**Request**:
- Method: `POST`
- Content-Type: `multipart/form-data`
- Body: Audio file (form field name: `file`)

**Supported Audio Formats**:
- WAV (recommended)
- MP3
- M4A
- MP4
- MOV
- FLAC
- OGG
- WebM

**Optional Headers**:
- `Authorization: Bearer YOUR_TOKEN` (if API token is configured)

**Response**:
```json
{
  "success": true,
  "text": "This is the transcribed text from the audio file.",
  "enhancedText": "This is the enhanced version of the transcribed text.",
  "metadata": {
    "model": "ggml-base.en",
    "language": "en",
    "duration": 5.5,
    "processingTime": 1.234,
    "transcriptionTime": 1.0,
    "enhancementTime": 0.234,
    "enhanced": true,
    "replacementsApplied": true
  }
}
```

**Error Response**:
```json
{
  "success": false,
  "error": "No model selected",
  "details": "Please select a transcription model in VoiceInk settings"
}
```

## Examples

### Using cURL

#### Basic Transcription
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@audio.wav"
```

#### With Authentication
```bash
curl -X POST http://localhost:5000/api/transcribe \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -F "file=@audio.wav"
```

#### Health Check
```bash
curl http://localhost:5000/health
```

### Using Python

```python
import requests

# Transcribe audio
with open('audio.wav', 'rb') as f:
    response = requests.post(
        'http://localhost:5000/api/transcribe',
        files={'file': f}
    )
    
result = response.json()
print(result['text'])
```

### Using JavaScript/Node.js

```javascript
const FormData = require('form-data');
const fs = require('fs');
const axios = require('axios');

const form = new FormData();
form.append('file', fs.createReadStream('audio.wav'));

axios.post('http://localhost:5000/api/transcribe', form, {
    headers: form.getHeaders()
}).then(response => {
    console.log(response.data.text);
});
```

### Using Swift

```swift
import Foundation

func transcribeAudio(fileURL: URL) async throws -> String {
    var request = URLRequest(url: URL(string: "http://localhost:5000/api/transcribe")!)
    request.httpMethod = "POST"
    
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    
    let audioData = try Data(contentsOf: fileURL)
    var body = Data()
    
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    
    request.httpBody = body
    
    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    
    return response.text
}
```

## Error Codes

| Status Code | Description |
|------------|-------------|
| 200 | Success |
| 400 | Bad Request (invalid audio format or missing file) |
| 401 | Unauthorized (invalid or missing API token) |
| 413 | Payload Too Large (audio file exceeds 500MB) |
| 500 | Internal Server Error |
| 503 | Service Unavailable (model not loaded) |

## Best Practices

1. **Audio Quality**: Use high-quality audio (16kHz or higher sample rate) for best results
2. **File Size**: Keep audio files under 100MB for optimal performance
3. **Format**: WAV format provides the best compatibility and performance
4. **Model Selection**: Choose appropriate model size based on accuracy vs speed requirements
5. **Error Handling**: Always check the `success` field in responses
6. **Timeouts**: Set appropriate timeouts for long audio files (processing time varies by model)

## Security Considerations

1. **Local Only by Default**: API only accepts connections from localhost unless explicitly configured
2. **API Token**: Use API tokens in production environments
3. **HTTPS**: For network access, consider using a reverse proxy with HTTPS
4. **Firewall**: Ensure proper firewall rules when enabling network access

## Troubleshooting

### API Server Not Responding
1. Check if VoiceInk is running
2. Verify API server is enabled in Settings > API
3. Check the port isn't blocked by firewall
4. Ensure no other service is using port 5000

### Transcription Errors
1. Verify a transcription model is selected in VoiceInk
2. Check audio file format is supported
3. Ensure audio file isn't corrupted
4. Check available disk space for temporary files

### Performance Issues
1. Use smaller models for faster processing
2. Reduce audio file size/duration
3. Disable AI enhancement if not needed
4. Check system resources (CPU/Memory)

## Advanced Configuration

### Using Different Models

VoiceInk supports multiple transcription models. Select the desired model in VoiceInk's main interface before making API requests.

**Local Models** (whisper.cpp):
- Tiny, Base, Small, Medium, Large
- Various quantized versions for performance

**Cloud Models**:
- OpenAI Whisper
- Groq Whisper
- Deepgram
- And more...

### AI Enhancement

When AI enhancement is enabled in VoiceInk settings, the API automatically:
- Improves transcription formatting
- Adds punctuation and capitalization
- Fixes common transcription errors
- Applies context-aware corrections

### Word Replacement

Configure custom word replacements in VoiceInk Settings > Dictionary to automatically:
- Fix common misrecognitions
- Expand abbreviations
- Apply custom terminology

## Integration Examples

### Obsidian Plugin
```javascript
// Example Obsidian plugin integration
async function transcribeToNote(audioFile) {
    const formData = new FormData();
    formData.append('file', audioFile);
    
    const response = await fetch('http://localhost:5000/api/transcribe', {
        method: 'POST',
        body: formData
    });
    
    const result = await response.json();
    
    if (result.success) {
        // Create new note with transcription
        await app.vault.create('Transcription.md', result.text);
    }
}
```

### Raycast Extension
```typescript
// Example Raycast extension
import { showToast, Toast } from "@raycast/api";

export default async function transcribeClipboard() {
  const response = await fetch("http://localhost:5000/api/transcribe", {
    method: "POST",
    body: formData
  });
  
  const result = await response.json();
  
  if (result.success) {
    await Clipboard.copy(result.text);
    await showToast(Toast.Style.Success, "Transcribed to clipboard");
  }
}
```

### Shortcuts Integration
Use the Shortcuts app on macOS to:
1. Record audio
2. Send to VoiceInk API
3. Process the transcription
4. Save to Notes, send via email, etc.

## Rate Limiting

The API server includes basic rate limiting:
- Default: 100 requests per minute
- Configurable in future versions
- Returns 429 status code when exceeded

## Roadmap

Future API enhancements planned:
- WebSocket support for real-time transcription
- Batch processing endpoint
- Speaker diarization parameters
- Custom vocabulary support
- Streaming transcription
- Multiple language detection

## Support

For issues or questions:
- GitHub Issues: [github.com/Beingpax/VoiceInk/issues](https://github.com/Beingpax/VoiceInk/issues)
- Documentation: This file
- In-app help: Settings > API > Show Test Instructions

## License

The VoiceInk API follows the same license as the main VoiceInk application. See LICENSE file in the repository root for details.