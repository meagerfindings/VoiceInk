# VoiceInk Speaker Diarization Implementation Plan

## Overview
Add speaker diarization capability to VoiceInk, allowing it to identify and label different speakers in audio transcriptions. This will be integrated with the existing API server to provide diarization via API requests.

## Architecture Design

### 1. Core Diarization Service
Create a new Swift service that handles speaker diarization using either:
- **Option A**: Native Apple Speech framework (if it supports diarization)
- **Option B**: Integration with pyannote.audio via Python bridge
- **Option C**: whisper.cpp's built-in diarization (if available in our version)

### 2. Components to Implement

#### VoiceInk/Services/SpeakerDiarizationService.swift
- Main service class for speaker diarization
- Methods:
  - `diarize(audioURL: URL) async throws -> DiarizationResult`
  - `alignTranscriptionWithDiarization(transcription: String, diarization: DiarizationResult) -> AlignedResult`
- Support for different diarization modes: fast, balanced, accurate

#### VoiceInk/Models/DiarizationModels.swift
- Data models:
  ```swift
  struct DiarizationResult {
      let segments: [DiarizationSegment]
      let speakers: [String]
      let numSpeakers: Int
      let totalDuration: TimeInterval
  }
  
  struct DiarizationSegment {
      let start: TimeInterval
      let end: TimeInterval
      let speaker: String
      let confidence: Double?
  }
  
  struct AlignedTranscription {
      let segments: [AlignedSegment]
      let speakers: [String]
      let text: String
      let textWithSpeakers: String
  }
  ```

#### VoiceInk/API/TranscriptionAPIHandler.swift (Update)
- Add diarization parameter to transcribe method
- Process diarization when requested
- Align transcription with speaker labels

#### VoiceInk/API/TranscriptionAPIServer.swift (Update)
- Update `/api/transcribe` endpoint to accept diarization parameters:
  - `enable_diarization`: Bool
  - `diarization_mode`: String (fast/balanced/accurate)
  - `min_speakers`: Int?
  - `max_speakers`: Int?

### 3. Implementation Approach

#### Phase 1: Basic Infrastructure
1. Create DiarizationModels.swift with data structures
2. Create SpeakerDiarizationService.swift skeleton
3. Update API models to include diarization parameters

#### Phase 2: Core Implementation
1. Investigate whisper.cpp's diarization capabilities
2. If whisper.cpp supports it:
   - Use whisper.cpp's built-in diarization (Metal-optimized)
3. If not:
   - Implement using Apple's Speech framework
   - Or create Python bridge to pyannote.audio

#### Phase 3: API Integration
1. Update TranscriptionAPIHandler to handle diarization
2. Add alignment logic to merge transcription with speaker labels
3. Update API response format to include speaker information

#### Phase 4: UI Integration (Optional)
1. Add diarization toggle in settings
2. Show speaker labels in transcription history
3. Color-code different speakers in UI

## Technical Considerations

### whisper.cpp Diarization
- Check if our whisper.cpp build includes diarization support
- If yes, enable with appropriate flags during transcription
- This would be the most performant option (Metal-optimized)

### Apple Speech Framework
- Investigate if SFSpeechRecognizer supports speaker diarization
- May be limited to specific languages or iOS versions

### Python Bridge Option
- Would require bundling Python runtime
- More complex but provides access to pyannote.audio
- Consider performance implications

## API Response Format

When diarization is enabled, the API response will include:

```json
{
  "success": true,
  "text": "Full transcription text",
  "segments": [
    {
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, how are you?",
      "speaker": "SPEAKER_00"
    },
    {
      "start": 2.5,
      "end": 4.2,
      "text": "I'm doing well, thanks!",
      "speaker": "SPEAKER_01"
    }
  ],
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "num_speakers": 2,
  "text_with_speakers": "[SPEAKER_00]: Hello, how are you?\n[SPEAKER_01]: I'm doing well, thanks!",
  "metadata": {
    "diarization_enabled": true,
    "diarization_mode": "balanced",
    "processing_time": 3.5
  }
}
```

## Testing Plan

1. Test with single speaker audio (should identify 1 speaker)
2. Test with 2-speaker conversation
3. Test with multi-speaker meeting recording
4. Test performance with different modes (fast/balanced/accurate)
5. Test API endpoint with various parameters

## Dependencies

- May need to add new Swift packages or frameworks
- Possible Python runtime if using pyannote bridge
- No additional dependencies if using whisper.cpp or Apple frameworks

## Next Steps

1. ✅ Investigate whisper.cpp diarization capabilities
2. ⬜ Create basic data models and service structure
3. ⬜ Implement diarization using chosen method
4. ⬜ Integrate with API
5. ⬜ Test and optimize