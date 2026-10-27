import AppKit
import BallastCore
import Foundation
import UserNotifications

/// Looks for a newer GitHub release at most once a day. Off when Info.plist has no BallastRepo.
@MainActor @Observable final class UpdateCheck {
    struct Release { var version: String; var url: URL }
    var available: Release?

    private let defaults = UserDefaults.standard
    let repo = (Bundle.main.object(forInfoDictionaryKey: "BallastRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BallastCore.version

    init() {
        if let v = defaults.string(forKey: "latestVersion"), let u = defaults.url(forKey: "latestURL").flatMap({ releaseLink($0.absoluteString) }) { offer(v, u) }
    }

    func check() async {
        guard repo.contains("/") else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400,
              let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let url = (json["html_url"] as? String).flatMap(releaseLink) else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        defaults.set(version, forKey: "latestVersion")
        defaults.set(url, forKey: "latestURL")
        offer(version, url)
        if let available, defaults.string(forKey: "notifiedVersion") != available.version {
            defaults.set(available.version, forKey: "notifiedVersion")
            await notify(available)
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

    private func offer(_ version: String, _ url: URL) {
        available = compareVersions(version, current) == .orderedDescending ? Release(version: version, url: url) : nil
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
