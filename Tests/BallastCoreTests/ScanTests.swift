import Foundation
import Testing
@testable import BallastCore

@Suite struct ScanTests {
    func scanner(_ f: Fixture, _ providers: [any Provider] = Providers.all) -> DiskScanner {
        DiskScanner(env: f.env(), providers: providers, summaryURL: f.url("state/summary.json"))
    }

    @Test func backgroundSkipsUserStart() async {
        let f = Fixture()
        f.file("Downloads/big.iso", bytes: 600_000)
        let reports = await scanner(f, [LargeFilesProvider(minBytes: 1000), OtherDevDataProvider()]).scan(background: true)
        #expect(!reports.contains { $0.id == "largeFiles" })
    }

    @Test func userStartRunsWhenNamed() async {
        let f = Fixture()
        f.file("Downloads/big.iso", bytes: 600_000)
        let reports = await scanner(f, [LargeFilesProvider(minBytes: 1000)]).scan(background: false, only: ["largeFiles"])
        #expect(reports.first { $0.id == "largeFiles" }?.items.count == 1)
    }

    @Test func writesSummary() async throws {
        let f = Fixture()
        f.file(".npm/_cacache/a", bytes: 50_000)
        f.file("Library/Application Support/Claude/vm_bundles/x", bytes: 200_000)
        let s = scanner(f, [PackageCachesProvider(), OtherDevDataProvider()])
        _ = await s.scan(background: true)
        #expect(FileManager.default.fileExists(atPath: f.url("state/summary.json").path))
        let summary = try #require(await s.lastSummary())
        #expect(summary.concerns.map(\.id) == ["otherDevData", "packageCaches"])
        #expect(summary.concerns.allSatisfy { $0.reclaimable <= $0.bytes })
        #expect(summary.concerns.last?.reclaimable == summary.concerns.last?.bytes)
        #expect(summary.totalBytes > 0)
    }

    @Test func onlyRescansSelected() async {
        let f = Fixture()
        f.file(".npm/_cacache/a", bytes: 50_000)
        f.file("Library/Application Support/Claude/vm_bundles/x", bytes: 200_000)
        let reports = await scanner(f, [PackageCachesProvider(), OtherDevDataProvider()]).scan(background: false, only: ["packageCaches"])
        #expect(reports.map(\.id) == ["packageCaches"])
        #expect(!FileManager.default.fileExists(atPath: f.url("state/summary.json").path))
    }

    @Test func emptyEnvironmentScansCleanly() async {
        let f = Fixture()
        let reports = await scanner(f).scan(background: true)
        #expect(reports.allSatisfy { $0.items.isEmpty })
    }
}
