import Foundation

@main
struct ForkUpdaterHarness {
    @MainActor
    static func main() {
        let suite = "ForkUpdaterHarness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "VoiceInkChecksForUpdatesOnLaunch")
        let updater = UpdaterViewModel(defaults: defaults)

        #if LOCAL_BUILD
            precondition(
                !updater.checksForUpdatesWhenDashboardAppears,
                "Local builds must ignore persisted automatic-update opt-in")
            updater.setChecksForUpdatesWhenDashboardAppears(true)
            precondition(
                !updater.checksForUpdatesWhenDashboardAppears,
                "Local builds must not enable dashboard update probes")
            updater.checkForUpdatesIfDue()
        #else
            precondition(
                updater.checksForUpdatesWhenDashboardAppears,
                "Standard builds must retain the persisted preference")
            updater.setChecksForUpdatesWhenDashboardAppears(false)
            precondition(
                !updater.checksForUpdatesWhenDashboardAppears,
                "Standard builds must honor explicit opt-out")
        #endif

        print("Fork updater harness: all tests passed")
    }
}
