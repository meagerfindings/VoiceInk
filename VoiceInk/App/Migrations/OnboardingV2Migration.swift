import Foundation

enum OnboardingV2Migration {
    private static let legacyCompletedKey = "hasCompletedOnboarding"
    static let completedKey = OnboardingSettings.completedV2Key
    private static let preparedKey = OnboardingSettings.preparedV2Key

    static func prepareIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey),
            !defaults.bool(forKey: preparedKey)
        else {
            return
        }

        defaults.removeObject(forKey: legacyCompletedKey)
        OnboardingStorageKeys.onboardingKeys.forEach {
            defaults.removeObject(forKey: $0)
        }
        defaults.set(true, forKey: preparedKey)
    }
}
