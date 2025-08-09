# VoiceInk API Documentation

## Overview

VoiceInk provides a built-in HTTP API server that enables external applications to leverage its powerful transcription capabilities. The API supports both basic transcription and advanced features like speaker diarization, AI enhancement, and word replacements.

## Table of Contents

- [Getting Started](#getting-started)
- [Authentication](#authentication)
- [API Endpoints](#api-endpoints)
  - [Health Check](#health-check)
  - [Transcribe Audio](#transcribe-audio)
- [Speaker Diarization](#speaker-diarization)
- [Error Handling](#error-handling)
- [Rate Limiting](#rate-limiting)
- [Examples](#examples)
- [SDKs and Libraries](#sdks-and-libraries)

## Getting Started

### Enabling the API Server

1. Open VoiceInk application
2. Navigate to **Settings** → **API**
3. Toggle **"Enable API Server"**
4. Configure settings:
   - **Port**: Default is 8080 (configurable)
   - **Allow Network Access**: Enable for remote connections (default: localhost only)

### Base URL

- Local only (default): `http://localhost:8080`
- Network access: `http://YOUR_IP:8080`

## Authentication

Currently, the API does not require authentication when accessed locally. For network access, ensure your firewall settings are properly configured.

**Note**: Authentication features are planned for future releases.

## API Endpoints

### Health Check

Check the API server status and get system information.

#### Request

```http
GET /health
```

#### Response

```json
{
  "status": "healthy",
  "service": "VoiceInk API",
  "version": "1.49",
  "timestamp": 1754776227.583462,
  "system": {
    "platform": "macOS",
    "osVersion": "Version 15.2 (Build 24C101)",
    "processorCount": 12,
    "memoryUsageMB": 202.5625,
    "uptimeSeconds": 131.40261900424957
  },
  "api": {
    "endpoint": "http://localhost:8080",
    "port": 8080,
    "isRunning": true,
    "requestsServed": 10,
    "averageProcessingTimeMs": 1250.5
  },
  "transcription": {
    "currentModel": "Large v3 Turbo (Quantized)",
    "modelLoaded": true,
    "availableModels": [
      "ggml-large-v3-turbo-q5_0"
    ],
    "enhancementEnabled": false,
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

### Transcribe Audio

Transcribe an audio file with optional speaker diarization and AI enhancement.

#### Request

```http
POST /api/transcribe
Content-Type: multipart/form-data
```

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `file` | File | Yes | Audio file to transcribe (WAV, MP3, M4A, FLAC, OGG, etc.) |
| `enable_diarization` | Boolean | No | Enable speaker diarization (default: false) |
| `diarization_mode` | String | No | Optimization mode: "fast", "balanced", or "accurate" (default: "balanced") |
| `min_speakers` | Integer | No | Minimum expected speakers for diarization |
| `max_speakers` | Integer | No | Maximum expected speakers for diarization |
| `use_tinydiarize` | Boolean | No | Use whisper.cpp's tinydiarize feature (requires tdrz models) |

#### Response (Without Diarization)

```json
{
  "success": true,
  "text": "This is the transcribed text from the audio file.",
  "enhancedText": "This is the AI-enhanced version of the transcription.",
  "metadata": {
    "model": "Large v3 Turbo",
    "language": "en",
    "duration": 5.234,
    "processingTime": 1.342,
    "transcriptionTime": 1.123,
    "enhancementTime": 0.219,
    "enhanced": true,
    "replacementsApplied": true
  }
}
```

#### Response (With Diarization)

```json
{
  "success": true,
  "text": "Full transcription text without speaker labels",
  "enhancedText": "AI-enhanced version if enhancement is enabled",
  "segments": [
    {
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, welcome to the meeting.",
      "speaker": "SPEAKER_00",
      "confidence": 0.95,
      "speakerConfidence": 0.88
    },
    {
      "start": 2.5,
      "end": 5.2,
      "text": "Thank you for having me.",
      "speaker": "SPEAKER_01",
      "confidence": 0.92,
      "speakerConfidence": 0.91
    }
  ],
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "numSpeakers": 2,
  "textWithSpeakers": "[SPEAKER_00]:\nHello, welcome to the meeting.\n\n[SPEAKER_01]:\nThank you for having me.",
  "metadata": {
    "model": "Large v3 Turbo",
    "language": "en",
    "duration": 5.234,
    "processingTime": 2.156,
    "transcriptionTime": 1.123,
    "diarizationTime": 0.814,
    "enhancementTime": 0.219,
    "enhanced": true,
    "diarizationEnabled": true,
    "diarizationMethod": "tinydiarize",
    "replacementsApplied": true
  }
}
```

## Speaker Diarization

VoiceInk supports multiple speaker diarization methods:

### 1. Stereo Channel Separation

Best for recordings where different speakers are on separate audio channels (e.g., phone recordings).

- **Method**: `stereo`
- **Requirements**: 2-channel audio file
- **Accuracy**: High for properly separated channels

### 2. Tinydiarize (Experimental)

Uses whisper.cpp's built-in speaker turn detection.

- **Method**: `tinydiarize`
- **Requirements**: Special tdrz models from whisper.cpp
- **Accuracy**: Moderate, better for clear speaker transitions
- **Performance**: Fast, runs alongside transcription

### 3. Future: Pyannote Integration

Framework is in place for future integration with pyannote.audio for advanced diarization.

- **Method**: `pyannote`
- **Status**: Not yet implemented
- **Planned Features**: Advanced speaker embeddings, better accuracy

### Diarization Modes

- **fast**: Optimized for speed, may sacrifice some accuracy
- **balanced**: Good balance between speed and accuracy (default)
- **accurate**: Maximum accuracy, slower processing

## Error Handling

The API returns standard HTTP status codes and JSON error responses.

### Error Response Format

```json
{
  "success": false,
  "error": {
    "code": "400",
    "message": "Invalid request: Missing audio file"
  }
}
```

### Common Error Codes

| Status Code | Description |
|-------------|-------------|
| 200 | Success |
| 400 | Bad Request - Invalid parameters or missing file |
| 404 | Not Found - Invalid endpoint |
| 500 | Internal Server Error - Processing failed |

## Rate Limiting

Currently, there are no rate limits on the API. However, the server processes requests sequentially, so performance may degrade with concurrent requests.

## Examples

### cURL Examples

#### Basic Transcription
```bash
curl -X POST http://localhost:8080/api/transcribe \
  -F "file=@audio.wav"
```

#### With Speaker Diarization
```bash
curl -X POST http://localhost:8080/api/transcribe \
  -F "file=@meeting.wav" \
  -F "enable_diarization=true" \
  -F "diarization_mode=accurate" \
  -F "min_speakers=2" \
  -F "max_speakers=5"
```

#### Health Check
```bash
curl http://localhost:8080/health | jq .
```

### Python Example

```python
import requests
import json

def transcribe_audio(file_path, enable_diarization=False):
    """
    Transcribe an audio file using VoiceInk API
    """
    url = "http://localhost:8080/api/transcribe"
    
    with open(file_path, 'rb') as audio_file:
        files = {'file': audio_file}
        data = {}
        
        if enable_diarization:
            data.update({
                'enable_diarization': 'true',
                'diarization_mode': 'balanced',
                'min_speakers': '2',
                'max_speakers': '4'
            })
        
        response = requests.post(url, files=files, data=data)
    
    if response.status_code == 200:
        result = response.json()
        if result['success']:
            print(f"Transcription: {result['text']}")
            
            if 'speakers' in result:
                print(f"\nSpeakers detected: {result['numSpeakers']}")
                print(f"\nText with speakers:")
                print(result['textWithSpeakers'])
                
                # Process individual segments
                for segment in result['segments']:
                    print(f"\n[{segment['speaker']}] ({segment['start']:.1f}s - {segment['end']:.1f}s):")
                    print(f"  {segment['text']}")
        else:
            print(f"Error: {result.get('error', 'Unknown error')}")
    else:
        print(f"HTTP Error: {response.status_code}")

# Example usage
transcribe_audio("meeting_recording.wav", enable_diarization=True)
```

### JavaScript/Node.js Example

```javascript
const FormData = require('form-data');
const fs = require('fs');
const axios = require('axios');

async function transcribeAudio(filePath, options = {}) {
  const form = new FormData();
  form.append('file', fs.createReadStream(filePath));
  
  if (options.enableDiarization) {
    form.append('enable_diarization', 'true');
    form.append('diarization_mode', options.mode || 'balanced');
    if (options.minSpeakers) form.append('min_speakers', options.minSpeakers);
    if (options.maxSpeakers) form.append('max_speakers', options.maxSpeakers);
  }
  
  try {
    const response = await axios.post('http://localhost:8080/api/transcribe', form, {
      headers: form.getHeaders()
    });
    
    if (response.data.success) {
      console.log('Transcription:', response.data.text);
      
      if (response.data.speakers) {
        console.log('\nSpeakers:', response.data.speakers.join(', '));
        console.log('\nFormatted transcript:');
        console.log(response.data.textWithSpeakers);
      }
    }
  } catch (error) {
    console.error('Error:', error.message);
  }
}

// Example usage
transcribeAudio('audio.wav', {
  enableDiarization: true,
  mode: 'accurate',
  minSpeakers: 2,
  maxSpeakers: 4
});
```

### Swift Example

```swift
import Foundation

func transcribeAudio(fileURL: URL, enableDiarization: Bool = false) async throws {
    let url = URL(string: "http://localhost:8080/api/transcribe")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    
    var body = Data()
    
    // Add file
    let fileData = try Data(contentsOf: fileURL)
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(fileData)
    body.append("\r\n".data(using: .utf8)!)
    
    // Add diarization parameters if enabled
    if enableDiarization {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"enable_diarization\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"diarization_mode\"\r\n\r\n".data(using: .utf8)!)
        body.append("balanced\r\n".data(using: .utf8)!)
    }
    
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body
    
    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    
    if response.success {
        print("Transcription: \(response.text)")
        if let speakers = response.speakers {
            print("Speakers: \(speakers.joined(separator: ", "))")
        }
    }
}
```

## SDKs and Libraries

Community-contributed SDKs and libraries for various languages:

- **Python**: [voiceink-python](https://github.com/community/voiceink-python) (Community)
- **Node.js**: [voiceink-js](https://github.com/community/voiceink-js) (Community)
- **Go**: [go-voiceink](https://github.com/community/go-voiceink) (Community)

*Note: These are community projects and not officially maintained by VoiceInk.*

## Integration Ideas

### Automation Workflows

- **Transcribe recordings automatically**: Watch a folder and transcribe new audio files
- **Meeting transcription**: Integrate with video conferencing tools
- **Podcast transcription**: Batch process podcast episodes with speaker labels
- **Voice journaling**: Create timestamped, speaker-labeled transcripts

### Development Tools

- **IDE plugins**: Transcribe voice comments directly in your code editor
- **CI/CD integration**: Transcribe audio test files in your pipeline
- **Documentation**: Convert voice notes to written documentation

### Accessibility

- **Real-time captioning**: Stream audio for live transcription
- **Multi-language support**: Transcribe and translate in one step
- **Meeting minutes**: Generate formatted meeting notes with speaker attribution

## Troubleshooting

### Common Issues

1. **Connection Refused**
   - Ensure API server is enabled in VoiceInk settings
   - Check the port number matches your configuration
   - Verify firewall settings if using network access

2. **No Model Loaded**
   - Open VoiceInk and ensure a transcription model is selected
   - Wait for the model to fully load before making API requests

3. **Diarization Not Working**
   - Verify audio file has multiple speakers
   - For tinydiarize, ensure you have tdrz models installed
   - Try different diarization modes for better results

4. **Slow Performance**
   - Check system resources (CPU, Memory)
   - Use smaller models for faster processing
   - Disable enhancement for speed improvement

## Future Enhancements

Planned features for future API versions:

- [ ] WebSocket support for real-time transcription
- [ ] Batch processing endpoint
- [ ] API key authentication
- [ ] Rate limiting and quotas
- [ ] Webhook notifications for async processing
- [ ] Custom vocabulary support via API
- [ ] Language detection endpoint
- [ ] Audio format conversion endpoint
- [ ] Streaming audio support
- [ ] Advanced diarization with speaker embeddings

## Support

For API-related issues or feature requests:

1. Check this documentation and examples
2. Search existing [GitHub issues](https://github.com/meagerfindings/VoiceInk/issues)
3. Create a new issue with the `api` label
4. Include your API request/response for debugging

## License

The VoiceInk API is part of the VoiceInk application and is covered under the same GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.