import Foundation
import Testing
@testable import BallastCore

@Suite struct SelfUpdateTests {
    static let asset = "https://github.com/linearza/ballast/releases/download/v0.5.4/Ballast-0.5.4.zip"

    @Test func picksTheAssetNamedForTheVersion() {
        let assets = [("Ballast-0.5.3.zip", "https://github.com/x/Ballast-0.5.3.zip"), ("Ballast-0.5.4.zip", Self.asset)]
        #expect(SelfUpdate.pickAsset(assets, version: "0.5.4") == URL(string: Self.asset))
    }

    @Test func missingOrMisnamedAssetGivesNil() {
        #expect(SelfUpdate.pickAsset([], version: "0.5.4") == nil)
        #expect(SelfUpdate.pickAsset([("Ballast-0.5.4.zip.sig", Self.asset)], version: "0.5.4") == nil)
        #expect(SelfUpdate.pickAsset([("Ballast-0.5.3.zip", Self.asset)], version: "0.5.4") == nil)
    }

    @Test func assetOnAForeignHostIsDropped() {
        #expect(SelfUpdate.pickAsset([("Ballast-0.5.4.zip", "https://evil.example/Ballast-0.5.4.zip")], version: "0.5.4") == nil)
    }

    @Test func allowListIsHttpsAndTheThreeGitHubHosts() {
        for ok in ["https://github.com/a/b.zip", "https://objects.githubusercontent.com/x", "https://release-assets.githubusercontent.com/x?y=1"] {
            #expect(SelfUpdate.isAllowedDownload(URL(string: ok)!), "\(ok)")
        }
        for bad in ["http://github.com/a.zip", "https://github.com.evil.example/a.zip", "https://evilgithub.com/a.zip",
                    "https://api.github.com/a", "https://githubusercontent.com/a", "https://user@github.com/a.zip",
                    "https://github.com:8443/a.zip", "file:///tmp/a.zip", "https://example.com/github.com"] {
            #expect(!SelfUpdate.isAllowedDownload(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func parsesReleaseWithAndWithoutAsset() {
        let with = Data(#"{"tag_name":"v0.5.4","html_url":"https://github.com/linearza/ballast/releases/tag/v0.5.4","assets":[{"name":"Ballast-0.5.4.zip","browser_download_url":"\#(Self.asset)"}]}"#.utf8)
        let r = SelfUpdate.parseRelease(with)
        #expect(r?.version == "0.5.4")
        #expect(r?.download == URL(string: Self.asset))
        let without = Data(#"{"tag_name":"v0.5.4","html_url":"https://github.com/linearza/ballast/releases/tag/v0.5.4"}"#.utf8)
        #expect(SelfUpdate.parseRelease(without)?.download == nil)
        #expect(SelfUpdate.parseRelease(without)?.page.host == "github.com")
        #expect(SelfUpdate.parseRelease(Data("{}".utf8)) == nil)
        #expect(SelfUpdate.parseRelease(Data(#"{"tag_name":"v1","html_url":"https://evil.example/r"}"#.utf8)) == nil)
    }

    private func check(id: String? = SelfUpdate.bundleID, version: String? = "0.5.4", offered: String = "0.5.4", running: String = "0.5.3",
                       exec: Bool = true, sig: Bool = true) -> SelfUpdate.Problem? {
        SelfUpdate.validate(bundleID: id, version: version, offered: offered, running: running, executableExists: exec, signatureValid: sig)
    }

    @Test func goodBundlePasses() { #expect(check() == nil) }

    @Test func eachDefectIsCaught() {
        #expect(check(id: "com.evil.app") == .wrongBundleID("com.evil.app"))
        #expect(check(id: nil) == .wrongBundleID(nil))
        #expect(check(version: "0.5.5") == .versionMismatch(found: "0.5.5", offered: "0.5.4"))
        #expect(check(exec: false) == .noExecutable)
        #expect(check(sig: false) == .badSignature)
    }

    @Test func mustBeStrictlyNewer() {
        #expect(check(version: "0.5.3", offered: "0.5.3", running: "0.5.3") == .notNewer(offered: "0.5.3", running: "0.5.3"))
        #expect(check(version: "0.5.2", offered: "0.5.2", running: "0.5.3") == .notNewer(offered: "0.5.2", running: "0.5.3"))
        #expect(check(version: "0.5.10", offered: "0.5.10", running: "0.5.9") == nil)
    }

    @Test func actionLogAppendsTabSeparatedLines() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ballast-log-\(UUID().uuidString)/actions.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        ActionLog.append(to: url, date: Date(timeIntervalSince1970: 0), outcome: "done", title: "Updated\tBallast", detail: "0.5.3 to 0.5.4")
        ActionLog.append(to: url, date: Date(timeIntervalSince1970: 0), outcome: "done", title: "b", detail: "c")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "1970-01-01T00:00:00Z\tdone\tUpdated Ballast\t0.5.3 to 0.5.4")
    }
}
