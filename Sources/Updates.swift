import AppKit
import Security
import Sparkle

/// App updates through Sparkle: the feed is the latest GitHub release's appcast.xml (SUFeedURL),
/// whose zip is EdDSA-signed by scripts/release.sh (SUPublicEDKey). Only Developer ID builds
/// update; a development build would replace itself with the release.
@MainActor @Observable
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Version of an update found by a scheduled check that is waiting in the menu bar menu
    /// (a menu bar app has no window to show it in at that moment).
    private(set) var pendingVersion: String?

    /// While true (recording or saving), "Install and Relaunch" waits.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// Called when `pendingVersion` changes.
    @ObservationIgnored var onChange: () -> Void = {}

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var postponedInstall: (() -> Void)?

    /// False for development builds: Check for Updates is disabled.
    var isEnabled: Bool { controller != nil }

    func start() {
        guard controller == nil, Self.isDeveloperIDSigned else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: self)
        updateCheck = Self.read(controller!.updater)
    }

    /// Check for Updates (Preferences › About, or the update item in the menu).
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// About › Check Automatically, kept in Sparkle's own settings.
    var updateCheck: UpdateCheck = AppSettings.Default.updateCheck {
        didSet {
            guard let updater = controller?.updater, Self.read(updater) != updateCheck else { return }
            if let interval = updateCheck.interval {
                updater.updateCheckInterval = interval
                updater.automaticallyChecksForUpdates = true
            } else {
                updater.automaticallyChecksForUpdates = false
            }
        }
    }

    private static func read(_ updater: SPUUpdater) -> UpdateCheck {
        guard updater.automaticallyChecksForUpdates else { return .off }
        let interval = updater.updateCheckInterval
        return [UpdateCheck.daily, .weekly, .monthly]
            .min { abs($0.interval! - interval) < abs($1.interval! - interval) }!
    }

    /// Recording or saving finished: run an install that was waiting for it.
    func idle() {
        guard let install = postponedInstall, !isBusy() else { return }
        postponedInstall = nil
        install()
    }

    private func setPending(_ version: String?) {
        guard pendingVersion != version else { return }
        pendingVersion = version
        onChange()
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        postponedInstall = installHandler
        return true
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check found an update: Sparkle shows it right away only when Meep was just
    /// launched; otherwise it waits in the menu.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if !handleShowingUpdate { setPending(version) }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setPending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setPending(nil) }
    }

    // MARK: Signature

    /// Signed with a Developer ID Application certificate (release builds).
    private static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(
                  "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString,
                  [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
