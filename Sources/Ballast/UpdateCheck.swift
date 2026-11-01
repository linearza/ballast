import AppKit
import BallastCore
import Foundation
import UserNotifications

/// Looks for a newer GitHub release at most once a day, on demand, and installs it in place.
/// Off when Info.plist has no BallastRepo.
@MainActor @Observable final class UpdateCheck {
    /// `download` is the release's zip when it has one; without it the release page is all we can offer.
    struct Release: Equatable { var version: String; var url: URL; var download: URL? }
    enum Phase: Equatable {
        case idle, checking, upToDate(String), failed(String)
        case downloading(Double), installing, installed(String)

        var busy: Bool {
            switch self {
            case .checking, .downloading, .installing, .installed: true
            default: false
            }
        }
    }

    var available: Release?
    var phase = Phase.idle

    private let defaults = UserDefaults.standard
    let repo = (Bundle.main.object(forInfoDictionaryKey: "BallastRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BallastCore.version
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    init() {
        if let v = defaults.string(forKey: "latestVersion"), let u = defaults.url(forKey: "latestURL").flatMap({ releaseLink($0.absoluteString) }) {
            offer(v, u, defaults.url(forKey: "latestDownload").flatMap { SelfUpdate.isAllowedDownload($0) ? $0 : nil })
        }
    }

    /// `notifying` false still finds the release, for Settings, and leaves the notification for a later check.
    func check(notifying: Bool = true) async {
        guard repo.contains("/") else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400, !phase.busy else { return }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        guard let info = try? await Installer.fetchLatest(repo: repo) else { return }
        record(info)
        if notifying, let available, defaults.string(forKey: "notifiedVersion") != available.version {
            defaults.set(available.version, forKey: "notifiedVersion")
            await notify(available)
        }
    }

    /// The Check for updates button: ignores the daily throttle and says what it found.
    func checkNow() async {
        guard repo.contains("/") else { return settle(.failed("This copy of Ballast has no update source.")) }
        guard !phase.busy else { return }
        phase = .checking
        defaults.set(Date(), forKey: "lastUpdateCheck")
        do {
            record(try await Installer.fetchLatest(repo: repo))
            settle(available == nil ? .upToDate(current) : .idle)
        } catch {
            settle(.failed(error.localizedDescription))
        }
    }

    /// The Update button: download, check, swap in and relaunch. `isCleaning` is asked again just before the swap.
    func install(isCleaning: @escaping @MainActor @Sendable () -> Bool) async {
        guard !phase.busy, let release = available, let zip = release.download else { return }
        guard !isCleaning() else { return settle(.failed("Finish the clean-up first.")) }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { return settle(.failed("Ballast isn't running from an app bundle, so it can't update itself.")) }
        let log = { (outcome: String, detail: String) in
            ActionLog.append(to: AppModel.logURL, date: Date(), outcome: outcome, title: "Update Ballast to \(release.version)", detail: detail)
        }
        phase = .downloading(0)
        do {
            try await Installer.run(version: release.version, from: zip, into: target, running: current, trashBackup: true,
                                    canSwap: { await !isCleaning() }) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = fraction >= 1 ? .installing : .downloading(fraction) }
                }
            }
        } catch {
            log("failed", error.localizedDescription)
            let writable = FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            return settle(.failed(error.localizedDescription + (writable ? "" : " Use What's new to download it yourself.")))
        }
        log("done", "\(current) to \(release.version), \(target.path)")
        phase = .installed(release.version)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        do {
            // The new copy sees this older one running and takes over (see SingleInstance); quitting here just makes it quicker.
            _ = try await NSWorkspace.shared.openApplication(at: target, configuration: config)
        } catch {
            return settle(.failed("Ballast \(release.version) is installed, but it wouldn't open. Open it from Applications."))
        }
        NSApp.terminate(nil)  // refused mid-clean; the row then says what to do
    }

    private func record(_ info: SelfUpdate.ReleaseInfo) {
        defaults.set(info.version, forKey: "latestVersion")
        defaults.set(info.page, forKey: "latestURL")
        defaults.set(info.download, forKey: "latestDownload")
        offer(info.version, info.page, info.download)
    }

    /// Shows a result for a few seconds, then goes back to idle.
    private func settle(_ result: Phase) {
        phase = result
        settleTask?.cancel()
        guard result != .idle else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.phase == result else { return }
            self.phase = .idle
        }
    }

    /// Once per version. Clicking it opens the release page.
    private func notify(_ release: Release) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ballast \(release.version) is out"
        content.body = "Click to see what's new and download it."
        content.userInfo = ["url": release.url.absoluteString]
        try? await center.add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))
    }

    private func offer(_ version: String, _ url: URL, _ download: URL?) {
        available = compareVersions(version, current) == .orderedDescending ? Release(version: version, url: url, download: download) : nil
    }
}

/// Opens a notification's release page when it's clicked, and shows notifications while Ballast is in front.
final class NotificationClicks: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationClicks()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["url"] as? String,
              let url = releaseLink(link) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
