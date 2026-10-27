import Foundation
@testable import BallastCore

/// A throwaway folder tree for one test. Removed when the fixture is released.
final class Fixture: @unchecked Sendable {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ballast-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Unreadable folders have to be made readable again before they can be removed.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            while let rel = e.nextObject() as? String { chmod(root.appending(path: rel).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ rel: String) -> URL { root.appending(path: rel) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 0, contents: String? = nil, modified: Date? = nil) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x61, count: bytes)
        try! data.write(to: u)
        if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        return u
    }

    @discardableResult
    func dir(_ rel: String) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func link(_ rel: String, to dest: String) -> URL {
        let u = url(rel)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: u.path, withDestinationPath: dest.hasPrefix("/") ? dest : url(dest).path)
        return u
    }

    @discardableResult
    func hardlink(_ rel: String, to dest: String) -> URL {
        let u = url(rel)
        try! FileManager.default.linkItem(at: url(dest), to: u)
        return u
    }

    @discardableResult
    func unreadable(_ rel: String) -> URL {
        let u = dir(rel)
        file("\(rel)/inside.bin", bytes: 4096)
        chmod(u.path, 0)
        return u
    }
}
