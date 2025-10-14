# VoiceInk - Agent Guidelines

## Key Commands
- **Build**: `xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug build`
- **Test**: `xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk test`
- **Format**: `swift-format -i -r VoiceInk/` (if installed)
- **Lint**: `swiftlint` (if installed)
- **Build whisper.cpp**: `./build-xcframework.sh` (required before first build)

## Architecture
- **State Management**: `WhisperState` is the central state container managing recording, transcription, and services
- **Service Protocol**: All transcription providers implement `TranscriptionService` protocol in `VoiceInk/Services/`
- **Providers**: LocalTranscriptionService (whisper.cpp), CloudTranscriptionService (OpenAI/Groq/Deepgram), NativeAppleTranscriptionService, ParakeetTranscriptionService
- **PowerMode**: Context-aware transcription that adapts based on active application (detects via AppleScript)
- **Data**: SwiftData for transcription history, UserDefaults for settings, Keychain for API keys
- **UI**: SwiftUI with NavigationSplitView, main views in `VoiceInk/Views/`

## Code Style
- Use `@MainActor` for UI updates from background tasks
- Follow existing Swift naming conventions (PascalCase for types, camelCase for variables/functions)
- Use protocol-oriented design for services (conform to existing protocols)
- Lazy-load models to reduce memory usage
- Clean up temporary audio files automatically
- Test using Swift Testing framework (`@Test` macro) in `VoiceInkTests/`
