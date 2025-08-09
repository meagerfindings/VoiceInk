# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceInk is a native macOS application for voice-to-text transcription that provides real-time, privacy-focused speech-to-text conversion. It supports both local AI models (via whisper.cpp) for 100% offline processing and various cloud transcription services.

## Key Commands

### Building the Project
```bash
# Build whisper.cpp framework (required before first build)
./build-xcframework.sh

# Open in Xcode for development
open VoiceInk.xcodeproj

# Build from command line
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug build

# Run tests
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk test
```

### Code Quality
```bash
# Format Swift code (if swift-format is installed)
swift-format -i -r VoiceInk/

# Lint Swift code (if SwiftLint is installed)
swiftlint
```

## Architecture Overview

### Core State Management
The application uses a centralized state management approach with `WhisperState` as the main state container. This class manages:
- Recording state and audio processing
- Transcription model selection and loading
- Service provider management
- User preferences and settings

### Service Layer Architecture
All transcription providers implement the `TranscriptionService` protocol, enabling seamless switching between:
- **LocalTranscriptionService**: Uses whisper.cpp for offline transcription
- **Cloud Services**: OpenAI, Groq, Deepgram, ElevenLabs, Mistral
- **ParakeetTranscriptionService**: FluidAudio Parakeet models
- **NativeAppleTranscriptionService**: Apple's Speech framework

### UI Architecture
The app uses SwiftUI with a NavigationSplitView structure:
- **ContentView**: Main container with sidebar navigation
- **Feature Views**: Each major feature has its own view in `VoiceInk/Views/`
- **Recording UI**: Multiple recording interfaces (MiniRecorderView, NotchRecorderView)

### PowerMode System
Context-aware transcription that adapts based on the active application:
- Detects current app and browser URLs via AppleScript
- Applies app-specific AI enhancement prompts
- Manages per-app configuration in `PowerModeView.swift`

### Data Persistence
- **SwiftData**: Used for transcription history storage
- **UserDefaults**: Application settings and preferences
- **Keychain**: Secure storage for API keys

## Development Guidelines

### Adding New Transcription Providers
1. Create a new service conforming to `TranscriptionService` protocol in `VoiceInk/Services/`
2. Implement required methods: `transcribe(audioFileURL:model:)` and `cancelTranscription()`
3. Add the service to `WhisperState` initialization
4. Update UI in `ModelManagementView` to support the new provider

### Working with Audio
- Audio recording uses `AVAudioRecorder` with specific format requirements
- Audio files are temporarily stored and automatically cleaned up
- Visual feedback provided through `AudioVisualizerView`

### Managing Permissions
The app requires several system permissions:
- Microphone access for recording
- Screen recording permission for PowerMode context detection
- Accessibility access for global hotkeys
- Check `PermissionsView.swift` for permission handling logic

### Testing Approach
- Unit tests are in `VoiceInkTests/` directory
- Uses Swift Testing framework (`@Test` macro)
- Focus testing on service layer and model logic
- UI testing through manual verification in Xcode

## Important Files and Their Roles

- `VoiceInk/VoiceInk.swift`: App entry point, initializes core services
- `VoiceInk/WhisperState.swift`: Central state management
- `VoiceInk/Services/TranscriptionService.swift`: Protocol defining transcription interface
- `VoiceInk/Views/ContentView.swift`: Main UI structure
- `VoiceInk/PowerMode/PowerModeView.swift`: Context-aware transcription configuration
- `VoiceInk/Models/Transcription.swift`: SwiftData model for history

## Common Tasks

### Updating Sparkle (Auto-update)
1. Update version in Xcode project settings
2. Archive and notarize the app
3. Update `appcast.xml` with new version details
4. Sign the update with Sparkle's EdDSA key

### Adding New UI Features
1. Create new view in `VoiceInk/Views/`
2. Add navigation case in `ContentView.swift`
3. Update `DynamicSidebar.swift` if needed
4. Follow existing SwiftUI patterns with `@StateObject` and `@EnvironmentObject`

### Debugging Transcription Issues
- Check `WhisperState.errorMessage` for service-specific errors
- Verify model is loaded: `WhisperState.isModelLoaded`
- Check audio file validity before transcription
- Review console logs for whisper.cpp output

## Performance Considerations

- Models are lazy-loaded to reduce memory usage
- Audio files are cleaned up automatically after transcription
- Use `@MainActor` for UI updates from background tasks
- Consider model size when recommending to users (smaller models for older Macs)