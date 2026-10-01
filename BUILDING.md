# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

The Refine/MLX dependency also needs Xcode's Metal toolchain. If it is missing, install it with `xcodebuild -downloadComponent MetalToolchain`.

## Local Build

```bash
git clone https://github.com/meagerfindings/VoiceInk.git
cd VoiceInk
make local-signed
open ~/Downloads/VoiceInk.app
```

`make local` prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

`make local-signed` uses the same build with this fork's Apple Development identity. An unavailable identity fails the build rather than silently producing an ad-hoc signature. Keep the same identity and Release bundle ID (`com.matgreten.VoiceInk`) to preserve macOS permissions across rebuilds.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

## Updating This Fork

The upstream base is tag `v2.21`; this fork corrects its source version metadata to `2.21` / build `221`. Do not use diagnostic prereleases as the normal upgrade target.

Start with a clean working tree, create an upgrade branch, fetch upstream tags, and merge the chosen stable tag. Preserve these fork contracts when resolving conflicts:

- Personal signing team, local entitlements, and `LOCAL_BUILD` in both configurations. Debug uses `com.matgreten.VoiceInk.dev`; Release retains `com.matgreten.VoiceInk`.
- Credentials remain in the existing `com.prakashjoshipax.VoiceInk` Data Protection Keychain service, including its synchronizable query behavior. Do not switch to upstream's `.Local` namespace or plaintext preferences.
- Automatic update checks stay disabled for local builds. Manual checks remain available, but updates should be installed by rebuilding this fork.
- New onboarding must preserve legacy/current mode configuration, active mode, and shortcuts so the existing Modes migration can read them.
- The Refine XPC bundle ID and `Shared/VoiceInkRefineXPCProtocol.swift` service name must agree.
- Retain upstream's `Package.resolved` revisions for the chosen tag rather than updating dependency branches independently.

Before launching an upgraded app against real data, quit VoiceInk and back up the old app plus:

- `~/Library/Application Support/com.prakashjoshipax.VoiceInk/` (history, dictionary, statistics, recordings, Whisper models)
- `~/Library/Preferences/com.matgreten.VoiceInk.plist`
- `~/Library/Application Support/VoiceInk/CustomSounds/`, if present

After building, run `scripts/test-fork-compatibility.sh` on macOS. It tests onboarding with disposable preferences, Keychain behavior with mocked Security calls (never real credentials), and update preferences with and without `LOCAL_BUILD`. It uses the built Sparkle framework from `.local-build/Build/Products/Release`; set `SPARKLE_FRAMEWORK_DIR` when using another derived-data directory.

Check the upgrade using copies of the stores before replacing `/Applications/VoiceInk.app`. A disposable home (`CFFIXED_USER_HOME`) isolates Foundation's store paths, but does **not** reliably isolate the preferences daemon. For app-level previews, copy the built app, give the copy a distinct preview bundle ID, and re-sign it with the same identity; use that distinct preferences domain as well as the disposable home. Never launch the production bundle ID against a test home and assume its preferences are isolated.

Verify history/dictionary migration, the selected transcription model, hotkeys, paste, Refine, restart, and sleep/wake. For rollback after first launch, restore the backed-up data and preferences as well as the old app; replacing only the executable does not undo store migrations.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `scripts/test-fork-compatibility.sh` — test fork credential, onboarding, and update compatibility
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. This fork sets `LOCAL_BUILD` in both configurations, including builds from Xcode.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
