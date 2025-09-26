# VoiceInk API Response Schema Documentation

## Overview

The VoiceInk API returns consistent, well-structured JSON responses across all endpoints. All responses include a `success` boolean field for easy client-side handling.

## Response Types

### 1. Transcription Success Response

**Endpoint:** `POST /api/transcribe`
**Content-Type:** `application/json`
**File Location:** `VoiceInk/API/TranscriptionAPIHandler.swift:425-441`

```json
{
  "success": true,
  "text": "The transcribed text from the audio file",
  "enhancedText": "AI-enhanced version of the text (optional)",
  "metadata": {
    "model": "whisper-base",
    "language": "auto",
    "duration": 123.45,
    "processingTime": 67.89,
    "transcriptionTime": 45.67,
    "enhancementTime": 22.22,
    "enhanced": true,
    "replacementsApplied": false
  }
}
```

#### Fields Description

| Field | Type | Description |
|-------|------|-------------|
| `success` | boolean | Always `true` for successful transcriptions |
| `text` | string | Original transcribed text |
| `enhancedText` | string\|null | AI-enhanced text (if enhancement is enabled) |
| `metadata.model` | string | Name of the transcription model used |
| `metadata.language` | string | Language setting ("auto" for auto-detection) |
| `metadata.duration` | number | Audio duration in seconds |
| `metadata.processingTime` | number | Total processing time in seconds |
| `metadata.transcriptionTime` | number | Time spent on transcription in seconds |
| `metadata.enhancementTime` | number\|null | Time spent on AI enhancement (if applicable) |
| `metadata.enhanced` | boolean | Whether AI enhancement was applied |
| `metadata.replacementsApplied` | boolean | Whether word replacements were applied |

### 2. Transcription Error Response

**Endpoint:** `POST /api/transcribe`
**Content-Type:** `application/json`
**File Location:** `VoiceInk/API/TranscriptionAPIHandler.swift:443-451`

```json
{
  "success": false,
  "error": {
    "code": "FILE_TOO_LARGE",
    "message": "File size (25.3MB) exceeds the 10.0MB limit for MP3 files in API transcriptions. MP3 files are particularly prone to processing issues. Large files can cause processing to hang indefinitely. Please use smaller audio files or split long recordings into segments."
  }
}
```

#### Error Codes

| Code | Description |
|------|-------------|
| `FILE_TOO_LARGE` | Audio file exceeds size limits |
| `NO_MODEL` | No transcription model is loaded |
| `INVALID_AUDIO` | Audio data is empty or corrupted |
| `INVALID_MP3_FORMAT` | MP3 file is corrupted or malformed |
| `AUDIO_TOO_LONG` | Audio duration exceeds time limits |
| `TRANSCRIPTION_TIMEOUT` | Transcription process timed out |

### 3. Health Check Response

**Endpoint:** `GET /health`
**Content-Type:** `application/json`
**File Location:** `VoiceInk/API/Models/HealthResponse.swift:5-44`

```json
{
  "status": "healthy",
  "service": "VoiceInk API",
  "version": "1.56",
  "timestamp": 1234567890.123,
  "system": {
    "platform": "macOS",
    "osVersion": "14.6.0",
    "processorCount": 8,
    "memoryUsageMB": 512.5,
    "uptimeSeconds": 3600.0,
    "powerSource": "AC Power",
    "isOnBattery": false,
    "batteryPercent": 85.0
  },
  "api": {
    "endpoint": "/api/transcribe",
    "port": 5000,
    "isRunning": true,
    "requestsServed": 42,
    "averageProcessingTimeMs": 2500.0
  },
  "transcription": {
    "currentModel": "whisper-base",
    "modelLoaded": true,
    "availableModels": ["whisper-tiny", "whisper-base", "whisper-small"],
    "enhancementEnabled": true,
    "wordReplacementEnabled": false,
    "isQueuePaused": false,
    "pauseReasons": [],
    "batteryOverrideProcessOnBattery": false
  },
  "capabilities": ["transcription", "enhancement", "diarization"]
}
```

### 4. Queue Response

**Endpoint:** `POST /api/transcribe` (when requests are queued)
**Content-Type:** `application/json`
**File Location:** `VoiceInk/API/WorkingHTTPServer.swift:810-824`

```json
{
  "success": true,
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "message": "Request queued for processing",
  "queue_position": 3,
  "estimated_wait_time_seconds": 45.0
}
```

## Schema Consistency Features

### ✅ Consistent Structure
- All responses include a `success` boolean field
- Error responses follow a structured `{code, message}` pattern
- JSON field naming follows consistent camelCase convention (with snake_case for queue response fields)

### ✅ Comprehensive Metadata
- Detailed timing information for performance monitoring
- Model and configuration information for debugging
- System status for health monitoring

### ✅ Error Handling
- Specific error codes for programmatic handling
- Detailed error messages for human consumption
- Timeout and resource limit protection

### ✅ Codified Implementation
- All response models defined as Swift `Codable` structs
- Consistent JSON encoding with pretty printing
- Type-safe field definitions prevent inconsistencies

## File Size and Duration Limits

| Format | Max Size | Max Duration | Notes |
|--------|----------|--------------|-------|
| MP3 | 10.0 MB | 8 minutes | Prone to processing issues |
| WAV/Other | 30.0 MB | 15 minutes | More reliable processing |

## Implementation Notes

- Responses are encoded using `JSONEncoder` with `.prettyPrinted` formatting
- All models conform to Swift's `Codable` protocol for type safety
- Error responses include detailed guidance for resolution
- Timeout protection prevents infinite processing loops
- Comprehensive logging for debugging and monitoring