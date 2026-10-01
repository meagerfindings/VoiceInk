#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-fork-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
SPARKLE_FRAMEWORK_DIR="${SPARKLE_FRAMEWORK_DIR:-$ROOT/.local-build/Build/Products/Release}"

swiftc "$ROOT/VoiceInk/App/Migrations/OnboardingV2Migration.swift" \
    "$ROOT/Tests/OnboardingV2MigrationHarness.swift" \
    -o "$BUILD_DIR/onboarding-test"
"$BUILD_DIR/onboarding-test"

for CONDITION in standard local; do
    if [ "$CONDITION" = local ]; then set -- -D LOCAL_BUILD; else set --; fi
    swiftc "$@" "$ROOT/VoiceInk/Infrastructure/Credentials/KeychainService.swift" \
        "$ROOT/Tests/ForkKeychainHarness.swift" -o "$BUILD_DIR/keychain-test"
    "$BUILD_DIR/keychain-test"

    swiftc "$@" -F "$SPARKLE_FRAMEWORK_DIR" -framework Sparkle \
        -Xlinker -rpath -Xlinker "$SPARKLE_FRAMEWORK_DIR" \
        "$ROOT/VoiceInk/App/Updates/UpdaterViewModel.swift" \
        "$ROOT/Tests/ForkUpdaterHarness.swift" -o "$BUILD_DIR/updater-test"
    CFFIXED_USER_HOME="$BUILD_DIR/home" "$BUILD_DIR/updater-test"
done
