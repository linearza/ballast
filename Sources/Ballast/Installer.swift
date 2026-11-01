import Foundation
import BallastCore

struct UpdateFailure: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Downloads, checks and swaps in a new Ballast.app. No UI and no relaunch: `UpdateCheck` and the
/// `BALLAST_SELFUPDATE_TEST` hook both drive it. Every failure leaves the installed app as it was.
enum Installer {
    /// Latest release from the GitHub API, for the update check and the test hook.
    static func fetchLatest(repo: String) async throws -> SelfUpdate.ReleaseInfo {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw UpdateFailure("No update source is set.") }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw UpdateFailure("Couldn't reach GitHub. Check your connection and try again.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let info = SelfUpdate.parseRelease(data) else {
            throw UpdateFailure("GitHub didn't give a usable answer. Try again later.")
        }
        return info
    }

    /// Download, unzip and validate, then swap `target` for the new bundle. Returns when `target` is the new version.
    static func run(version: String, from zip: URL, into target: URL, running: String, trashBackup: Bool,
                    canSwap: @escaping @Sendable () async -> Bool = { true },
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateFailure("Ballast can't replace itself in \(parent.path) because that folder isn't writable.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "ballast-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appending(path: "Ballast-\(version).zip")
        try await Downloader(destination: archive, progress: progress).download(zip)

        let fresh = try await Task.detached { try unpackAndValidate(archive, in: work, version: version, running: running) }.value
        guard await canSwap() else { throw UpdateFailure("Finish the clean-up first.") }
        try await Task.detached { try swap(fresh, into: target, version: version, trashBackup: trashBackup) }.value
    }

    // MARK: - Steps

    static func unpackAndValidate(_ archive: URL, in work: URL, version: String, running: String) throws -> URL {
        let out = work.appending(path: "unpacked")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard sh("/usr/bin/ditto", ["-x", "-k", archive.path, out.path]).status == 0 else {
            throw UpdateFailure("The download couldn't be unzipped, so nothing was changed.")
        }
        let app = out.appending(path: SelfUpdate.appName)
        let isDir = (try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        guard isDir?.isDirectory == true, isDir?.isSymbolicLink != true else {
            throw UpdateFailure("The download doesn't contain \(SelfUpdate.appName), so nothing was changed.")
        }
        _ = sh("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])  // not present on URLSession downloads; harmless
        if let problem = validate(app, offered: version, running: running) { throw UpdateFailure(problem.message) }
        return app
    }

    static func validate(_ app: URL, offered: String, running: String) -> SelfUpdate.Problem? {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        let exe = (info?["CFBundleExecutable"] as? String).map { app.appending(path: "Contents/MacOS/\($0)").path }
        return SelfUpdate.validate(
            bundleID: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String,
            offered: offered, running: running,
            executableExists: exe.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false,
            signatureValid: sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0)
    }

    /// Atomic swap that keeps the old bundle as a backup until the new one is confirmed in place.
    static func swap(_ fresh: URL, into target: URL, version: String, trashBackup: Bool) throws {
        let fm = FileManager.default
        let backupName = "Ballast.app.update-backup"
        let backup = target.deletingLastPathComponent().appending(path: backupName)
        try? fm.removeItem(at: backup)  // a leftover of our own from an earlier crash
        let placed: URL?
        do {
            placed = try fm.replaceItemAt(target, withItemAt: fresh, backupItemName: backupName, options: [.withoutDeletingBackupItem])
        } catch {
            throw UpdateFailure("Couldn't replace Ballast (\(error.localizedDescription)). The current copy is untouched.")
        }
        let now = NSDictionary(contentsOf: (placed ?? target).appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        guard now == version else {
            // Put the old one back.
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: backup, to: target)
            }
            throw UpdateFailure("The new copy didn't land properly, so the old one was put back.")
        }
        if fm.fileExists(atPath: backup.path) {
            if trashBackup { if (try? fm.trashItem(at: backup, resultingItemURL: nil)) == nil { try? fm.removeItem(at: backup) } }
            else { try? fm.removeItem(at: backup) }
        }
    }

    @discardableResult
    static func sh(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Fetches one file with progress, refusing any hop (first URL or redirect) off the allow-list.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: UpdateFailure?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = progress
    }

    func download(_ url: URL) async throws {
        guard SelfUpdate.isAllowedDownload(url) else { throw UpdateFailure("The download isn't from GitHub, so Ballast won't fetch it.") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let next = request.url, SelfUpdate.isAllowedDownload(next) {
            completionHandler(request)
        } else {
            failure = UpdateFailure("The download was sent somewhere other than GitHub, so it was stopped.")
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytes: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { onProgress(min(1, Double(written) / Double(expected))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        guard http?.statusCode == 200, let final = http?.url, SelfUpdate.isAllowedDownload(final) else {
            failure = UpdateFailure("GitHub didn't hand over the download (status \(http?.statusCode ?? 0)).")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch {
            failure = UpdateFailure("Couldn't save the download: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let failure { c.resume(throwing: failure) }
        else if error != nil { c.resume(throwing: UpdateFailure("The download failed. Check your connection and try again.")) }
        else { c.resume() }
    }
}

/// `BALLAST_SELFUPDATE_TEST=<bundle>` runs the whole pipeline against that bundle (as if it were the running
/// app) using the latest real release, prints each step and exits. No window, no relaunch.
final class Counter: @unchecked Sendable {
    private var value = -1
    private let lock = NSLock()
    func swap(_ new: Int) -> Int { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
}

enum SelfUpdateTestHook {
    static var target: URL? {
        ProcessInfo.processInfo.environment["BALLAST_SELFUPDATE_TEST"].map { URL(filePath: $0) }
    }

    static func run(_ target: URL) async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let repo = env["BALLAST_SELFUPDATE_REPO"] ?? "linearza/ballast"
        let running = NSDictionary(contentsOf: target.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "0"
        print("target: \(target.path)\nrunning version: \(running)")
        do {
            let latest = try await Installer.fetchLatest(repo: repo)
            print("latest release: \(latest.version)\nasset: \(latest.download?.absoluteString ?? "none")")
            guard let zip = latest.download else { print("FAIL: no asset"); return 2 }
            let last = Counter()
            try await Installer.run(version: latest.version, from: zip, into: target, running: running, trashBackup: false) { f in
                let pct = Int(f * 100) / 25 * 25
                if pct != last.swap(pct) { print("download \(pct)%") }
            }
            let now = NSDictionary(contentsOf: target.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            let problem = Installer.validate(target, offered: latest.version, running: running)
            print("installed version: \(now ?? "?")\nvalidation of installed bundle: \(problem == nil ? "ok" : "\(problem!)")")
            return now == latest.version ? 0 : 3
        } catch {
            print("REFUSED: \(error.localizedDescription)")
            return 1
        }
    }
}
