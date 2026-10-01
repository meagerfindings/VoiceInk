import Foundation

// Compile with VoiceInk/App/Migrations/OnboardingV2Migration.swift:
// swiftc VoiceInk/App/Migrations/OnboardingV2Migration.swift Tests/OnboardingV2MigrationHarness.swift -o /tmp/onboarding-v2-migration-test && /tmp/onboarding-v2-migration-test
enum OnboardingSettings {
    static let completedV2Key = "hasCompletedOnboardingV2"
    static let preparedV2Key = "hasPreparedOnboardingV2"
}

enum OnboardingStorageKeys {
    static let onboardingKeys = [
        "onboardingStage",
        "onboardingActivePermission",
        "onboardingRequestedScreenRecording",
        "onboardingAIProvider",
        "onboardingTranscriptionSetupKind",
        "onboardingTranscriptionProvider",
        "onboardingSkippedAPISetup",
        "onboardingExperienceIndex",
        "onboardingStarterModeIndex",
    ]
}

@main
struct OnboardingV2MigrationHarness {
    private static let legacyConfigurationKey = "powerModeConfigurationsV2"
    private static let configurationKey = "modeConfigurationsV2"
    private static let activeConfigurationKey = "activeConfigurationId"

    static func main() {
        testFirstPreparationPreservesModesAndClearsOnboardingState()
        testPreparedProfileIsIdempotent()
        testCompletedProfileIsPreserved()
        print("OnboardingV2Migration harness: all tests passed")
    }

    private static func testFirstPreparationPreservesModesAndClearsOnboardingState() {
        let defaults = makeDefaults()
        defer { removeSuite(defaults) }
        let id = "12345678-1234-1234-1234-123456789abc"
        let legacyShortcut = "Shortcut_powerMode_\(id)"
        let currentShortcut = "Shortcut_mode_\(id)"

        defaults.set(Data("legacy-modes".utf8), forKey: legacyConfigurationKey)
        defaults.set(Data("current-modes".utf8), forKey: configurationKey)
        defaults.set(id, forKey: activeConfigurationKey)
        defaults.set(Data("legacy-shortcut".utf8), forKey: legacyShortcut)
        defaults.set(true, forKey: "\(legacyShortcut)_cleared")
        defaults.set(Data("current-shortcut".utf8), forKey: currentShortcut)
        // Deliberately asymmetric marker state: the current shortcut's cleared marker is absent.
        for key in OnboardingStorageKeys.onboardingKeys {
            defaults.set("stale-\(key)", forKey: key)
        }
        defaults.set(true, forKey: "hasCompletedOnboarding")

        OnboardingV2Migration.prepareIfNeeded(defaults: defaults)

        expect(defaults.data(forKey: legacyConfigurationKey) == Data("legacy-modes".utf8), "legacy modes preserved")
        expect(defaults.data(forKey: configurationKey) == Data("current-modes".utf8), "current modes preserved")
        expect(defaults.string(forKey: activeConfigurationKey) == id, "active configuration preserved")
        expect(defaults.data(forKey: legacyShortcut) == Data("legacy-shortcut".utf8), "legacy shortcut preserved")
        expect(defaults.bool(forKey: "\(legacyShortcut)_cleared"), "legacy cleared marker preserved")
        expect(defaults.data(forKey: currentShortcut) == Data("current-shortcut".utf8), "current shortcut preserved")
        expect(defaults.object(forKey: "\(currentShortcut)_cleared") == nil, "absent current marker remains absent")
        expect(defaults.object(forKey: "hasCompletedOnboarding") == nil, "legacy completion flag cleared")
        for key in OnboardingStorageKeys.onboardingKeys {
            expect(defaults.object(forKey: key) == nil, "onboarding key cleared: \(key)")
        }
        expect(defaults.bool(forKey: OnboardingSettings.preparedV2Key), "profile marked prepared")
    }

    private static func testPreparedProfileIsIdempotent() {
        let defaults = makeDefaults()
        defer { removeSuite(defaults) }
        defaults.set(true, forKey: OnboardingSettings.preparedV2Key)
        seedPreservedState(defaults)
        let before = snapshot(defaults)

        OnboardingV2Migration.prepareIfNeeded(defaults: defaults)

        expectSnapshotsEqual(snapshot(defaults), before, "second preparation preserves all stored state")
    }

    private static func testCompletedProfileIsPreserved() {
        let defaults = makeDefaults()
        defer { removeSuite(defaults) }
        defaults.set(true, forKey: OnboardingV2Migration.completedKey)
        seedPreservedState(defaults)
        let before = snapshot(defaults)

        OnboardingV2Migration.prepareIfNeeded(defaults: defaults)

        expectSnapshotsEqual(snapshot(defaults), before, "completed v2 profile preserves all stored state")
    }

    private static func seedPreservedState(_ defaults: UserDefaults) {
        defaults.set(Data("legacy".utf8), forKey: legacyConfigurationKey)
        defaults.set(Data("current".utf8), forKey: configurationKey)
        defaults.set("active-id", forKey: activeConfigurationKey)
        defaults.set(Data("old shortcut".utf8), forKey: "Shortcut_powerMode_marker")
        defaults.set(true, forKey: "Shortcut_powerMode_marker_cleared")
        defaults.set(Data("new shortcut".utf8), forKey: "Shortcut_mode_marker")
        defaults.set("legacy onboarding", forKey: "hasCompletedOnboarding")
        for key in OnboardingStorageKeys.onboardingKeys {
            defaults.set("state-\(key)", forKey: key)
        }
    }

    private static func snapshot(_ defaults: UserDefaults) -> [String: Any] {
        defaults.persistentDomain(forName: suiteName) ?? [:]
    }

    private static func expectSnapshotsEqual(
        _ actual: [String: Any],
        _ expected: [String: Any],
        _ message: String
    ) {
        expect(
            NSDictionary(dictionary: actual).isEqual(NSDictionary(dictionary: expected)),
            message
        )
    }

    private static let suiteName = "OnboardingV2MigrationHarness.\(UUID().uuidString)"

    private static func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create disposable UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func removeSuite(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}
