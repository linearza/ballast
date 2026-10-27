import Testing
@testable import BallastCore

@Test func version() {
    #expect(BallastCore.version.isEmpty == false)
}

@Test func comparesVersions() {
    #expect(compareVersions("0.10.0", "0.9.1") == .orderedDescending)
    #expect(compareVersions("v1.0.0", "1.0.0") == .orderedSame)
    #expect(compareVersions("1.0", "1.0.1") == .orderedAscending)
    #expect(compareVersions("1.0", "1.0.0") == .orderedSame)
}
